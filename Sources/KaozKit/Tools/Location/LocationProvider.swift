import CoreLocation
import Foundation

/// Errors surfaced by the location tool to the model. Each maps to a clear
/// reason the user can act on (grant permission, reconnect, etc.).
enum LocationError: Error, LocalizedError, Equatable {
    case denied
    case restricted
    case unavailable(message: String)

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Location access denied. Allow TyKaoz in System Settings → Privacy & Security → Location Services."
        case .restricted:
            return "Location access is restricted by the device configuration."
        case .unavailable(let message):
            return "Localisation indisponible : \(message)"
        }
    }
}

/// Diagnostic signals observed while waiting for a fix. When the wait times
/// out, they turn a mute "no fix" into an actionable message. Pure value —
/// the message builder is unit-tested without CoreLocation.
struct LocationFixSignals: OptionSet, Sendable {
    let rawValue: Int

    /// The system reported it cannot determine the position. A Mac has no GPS:
    /// it triangulates from the Wi-Fi access points around it, so in a sparse
    /// area the computation is marginal and often fails outright.
    static let locationUnavailable = LocationFixSignals(rawValue: 1 << 0)
    /// The authorization prompt is still on screen.
    static let authorizationRequestInProgress = LocationFixSignals(rawValue: 1 << 1)
    /// The system considers the app not "in use" enough to serve it.
    static let insufficientlyInUse = LocationFixSignals(rawValue: 1 << 2)

    var timeoutMessage: String {
        if contains(.locationUnavailable) {
            // Asking again is worth it: the session stays warm, so a fix that
            // lands after this timeout serves the next call immediately.
            return """
            the system has no position yet. A Mac has no GPS: it locates \
            itself by triangulating the Wi-Fi networks around it, and where \
            they are few the fix often fails or takes several minutes. The \
            search goes on in the background — ask again a little later.
            """
        }
        if contains(.authorizationRequestInProgress) {
            return "authorization pending — answer the macOS prompt, then retry."
        }
        if contains(.insufficientlyInUse) {
            return "macOS considers the app inactive — bring TyKaoz to the front, then retry."
        }
        return "no fix within the time limit"
    }
}

/// The "is this fix good enough?" decision, kept as a pure value: the provider
/// itself talks to the real location daemon and cannot run in CI.
enum LocationFixPolicy {
    /// Under this age a cached fix answers the question as well as a new one
    /// would. Same threshold as `CurrentLocationTool.staleFixAge`, past which
    /// the tool already caveats the age to the model.
    static let freshFixMaxAge: TimeInterval = 300

    /// Core Location signals "no fix" with a negative horizontal accuracy.
    static func isUsable(_ fix: CLLocation) -> Bool {
        fix.horizontalAccuracy >= 0
    }

    /// Good enough to return without waiting for a better one.
    static func isFresh(_ fix: CLLocation) -> Bool {
        isUsable(fix) && -fix.timestamp.timeIntervalSinceNow <= freshFixMaxAge
    }
}

/// Abstracts the underlying Core Location bits so the tool stays testable.
public protocol LocationProviding: Sendable {
    func currentLocation() async throws -> CLLocation
}

/// Uses `CLLocationUpdate.liveUpdates()` for the actual fix because the
/// delegate-based API was unreliable in practice: `requestLocation()` aborts
/// on the first transient `kCLErrorLocationUnknown`, and re-using
/// `startUpdatingLocation()` after a previous stop sometimes never re-delivers
/// an event. `CLServiceSession` would be the iOS path here; on macOS we still
/// drive authorization through `CLLocationManager`.
@MainActor
public final class AppleLocationProvider: NSObject, CLLocationManagerDelegate, LocationProviding {
    public static let shared = AppleLocationProvider()

    /// Cold Wi-Fi-based fixes routinely exceed 25 s on macOS. The
    /// shared session below means this wait is paid once, not on every call.
    private static let fixTimeout: Duration = .seconds(40)
    /// How long the session keeps running with nothing to show for it, so a
    /// fix arriving after a timeout still serves the retry. When `locationd`
    /// comes up empty it only rescans every 300 s (its `nexttimer`), so a
    /// shorter window would expire before the next scan and learn nothing.
    /// Only ever reached on failure: the monitor stops early once a fix lands.
    private static let monitorLifetime: Duration = .seconds(330)
    private static let pollInterval: Duration = .milliseconds(250)

    private let manager = CLLocationManager()
    private var authorizationContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var lastFix: CLLocation?
    /// Diagnostic signals seen during the current fix attempt.
    private var signals: LocationFixSignals = []
    /// The shared `liveUpdates()` consumer, when one is running.
    private var monitor: Task<Void, Never>?
    /// Calls currently waiting on a fix. The monitor stops once a fix has
    /// landed and this is back to zero.
    private var activeRequests = 0
    /// A definitive authorization failure seen mid-stream.
    private var streamError: LocationError?

    override init() {
        super.init()
        manager.delegate = self
    }

    public func currentLocation() async throws -> CLLocation {
        if let cached = lastFix, LocationFixPolicy.isFresh(cached) {
            return cached
        }

        // Global Location Services switch off → fail fast with the fix,
        // instead of a mute timeout. The API blocks, so query off-main.
        let servicesEnabled = await Task.detached {
            CLLocationManager.locationServicesEnabled()
        }.value
        guard servicesEnabled else {
            throw LocationError.unavailable(message: """
                Location Services are off — turn them on in \
                System Settings → Privacy & Security → Location Services.
                """)
        }

        let status = await ensureAuthorized()
        switch status {
        case .denied:     throw LocationError.denied
        case .restricted: throw LocationError.restricted
        default:          break
        }

        signals = []
        streamError = nil
        activeRequests += 1
        defer { activeRequests -= 1 }
        startMonitorIfNeeded()

        let clock = ContinuousClock()
        let deadline = clock.now + Self.fixTimeout
        while clock.now < deadline {
            if let error = streamError { throw error }
            if let fix = lastFix, LocationFixPolicy.isFresh(fix) { return fix }
            // Polling rather than a continuation registry: it cannot resume
            // the same waiter twice, and 250 ms is nothing next to a Wi-Fi
            // scan followed by a geocode round trip.
            try await Task.sleep(for: Self.pollInterval)
        }

        if let error = streamError { throw error }
        // A known position, however old, beats an error: the tool flags its
        // age to the model, and a Mac that has not moved is still where it was.
        if let fix = lastFix, LocationFixPolicy.isUsable(fix) { return fix }
        throw LocationError.unavailable(message: signals.timeoutMessage)
    }

    /// One shared `liveUpdates()` session, kept warm across calls. Cold
    /// Wi-Fi-based positioning often outlasts a single tool call; re-opening a
    /// session per call made every retry restart from cold and fail alike.
    private func startMonitorIfNeeded() {
        guard monitor == nil else { return }
        monitor = Task { @MainActor [weak self] in
            await self?.runMonitor()
            self?.monitor = nil
        }
    }

    private func runMonitor() async {
        // `liveUpdates()` only *observes* positioning — it reports flags and
        // authorization changes but never asks the system to locate us, so on
        // its own the stream says "locationUnavailable" once and goes quiet.
        // `startUpdatingLocation()` is what actually drives a Wi-Fi scan; the
        // delegate below feeds the fixes back. Starting it once per monitor
        // rather than once per call also avoids the start/stop churn that made
        // the delegate API unreliable before.
        manager.startUpdatingLocation()
        defer { manager.stopUpdatingLocation() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                await self?.consumeUpdates()
            }
            group.addTask { @MainActor in
                try? await Task.sleep(for: Self.monitorLifetime)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func consumeUpdates() async {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied || update.authorizationDeniedGlobally {
                    streamError = .denied
                    return
                }
                if update.authorizationRestricted {
                    streamError = .restricted
                    return
                }
                // Record diagnostic hints so a timeout can explain itself.
                if update.locationUnavailable {
                    signals.insert(.locationUnavailable)
                }
                if update.authorizationRequestInProgress {
                    signals.insert(.authorizationRequestInProgress)
                }
                if update.insufficientlyInUse {
                    signals.insert(.insufficientlyInUse)
                }
                if let location = update.location,
                   LocationFixPolicy.isUsable(location) {
                    lastFix = location
                    signals = []
                    // Nobody is waiting any more: stop scanning, so the menu
                    // bar indicator goes out. After a timeout this is zero
                    // with no fix yet — `monitorLifetime` then keeps the
                    // stream open long enough to catch the late one.
                    if activeRequests == 0 { return }
                }
            }
        } catch {}
    }

    private func ensureAuthorized() async -> CLAuthorizationStatus {
        let current = manager.authorizationStatus
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        Task { @MainActor in
            guard let location = locations.last,
                  LocationFixPolicy.isUsable(location) else { return }
            lastFix = location
            signals = []
            // Nobody is waiting any more: stop scanning so the menu bar
            // indicator goes out rather than lingering for the whole lifetime.
            if activeRequests == 0 { monitor?.cancel() }
        }
    }

    public nonisolated func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        Task { @MainActor in
            guard let clError = error as? CLError else { return }
            switch clError.code {
            case .denied:
                streamError = .denied
            case .locationUnknown:
                // Transient: the scan has not converged yet. Keep waiting —
                // abandoning here is what made `requestLocation()` unusable.
                signals.insert(.locationUnavailable)
            default:
                break
            }
        }
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined,
                  let continuation = authorizationContinuation else { return }
            authorizationContinuation = nil
            continuation.resume(returning: manager.authorizationStatus)
        }
    }
}
