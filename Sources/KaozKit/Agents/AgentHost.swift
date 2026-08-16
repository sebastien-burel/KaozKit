import Foundation
import KaozJS
import KaozJSCore      // xsBridgeAddModuleRoot / xsBridgeClearModuleRoots / xsBridgeSetContext
import KaozHostC   // xsBridgeTyKaozRegister (host table, before restoring a snapshot)

/// A **resident** agent: one `XSEngine` kept alive across many deliveries.
///
/// Unlike the one-shot `AgentSession` (run → report → teardown), the engine and
/// its JS heap persist between calls. The agent module is imported once; each
/// `deliver(kind:payload:)` routes to its handler (`onMessage`/`onEvent`/
/// `onTick`, or a legacy `run`/default function) and settles that one delivery
/// by id — the engine stays alive for the next one, so JS-side state (counters,
/// conversation, caches) survives across turns.
///
/// Thread model unchanged: all XS access is marshalled onto the engine's
/// dedicated run-loop thread; `deliver` is `async` and returns the handler's
/// JSON result. Deliveries may overlap (each awaits its own id) — the JS side is
/// single-threaded, so handlers interleave only at `await` boundaries, exactly
/// like a browser event loop.
public nonisolated final class AgentHost: @unchecked Sendable {

    private let engine: XSEngine
    private let host: TyKaozHost
    /// Absolute path of the bundled orchestrator, or nil when this host drives a
    /// legacy heap (see `legacyHeap`).
    private let orchestrator: String?
    /// A heap restored from a snapshot written before the orchestrator had
    /// exports. Its module namespace has no `deliver`, so calling one would
    /// reject asynchronously and the delivery would never settle — those hosts
    /// keep using the global entry points the restored heap does have.
    private let legacyHeap: Bool

    // Self-scheduling (host.schedule/every/cancel): armed timers deliver ticks.
    private var timers: [UInt32: DispatchSourceTimer] = [:]
    private var nextTimerHandle: UInt32 = 1

    // Checkpointing (host.snapshot / checkpointEveryDelivery). The heap can only
    // be written between deliveries — never from inside one — so a request is
    // recorded here and honoured once the delivery that made it has settled.

    /// Where a checkpoint goes. Nil means this host does not persist: JS gets
    /// `false` from `host.snapshot()` and nothing is ever written.
    public var snapshotSink: (@Sendable (Data) throws -> Void)?
    /// Checkpoint after *every* settled delivery, without JS asking. A tick is a
    /// delivery, so this also covers work driven by `host.every`.
    public var checkpointEveryDelivery = false
    /// How long a checkpoint waits for in-flight host calls to settle before
    /// giving up (a snapshot needs `pendingCount == 0`).
    public var checkpointSettleTimeout: TimeInterval = 30
    private var checkpointRequested = false          // guarded by `lock`
    private let checkpointQueue = DispatchQueue(label: "kaoz.agent.checkpoint")
    /// True when this host was revived from a snapshot whose heap can route a
    /// `restore` delivery — see `resumeFromSnapshot`.
    private var restoreInfo: [String: Any]?

    /// One in-flight delivery: its awaiting continuation + optional timeout item.
    private struct Delivery {
        let cont: CheckedContinuation<String, Error>
        let timeoutItem: DispatchWorkItem?
    }
    private let lock = NSLock()
    private var pending: [UInt32: Delivery] = [:]
    private var nextId: UInt32 = 1
    private var closed = false

    /// Remove a delivery (settle/timeout/close), cancelling its timeout. Caller
    /// must NOT hold `lock`. Returns the continuation to resume, or nil if gone.
    private func take(_ id: UInt32) -> CheckedContinuation<String, Error>? {
        lock.lock()
        let d = pending.removeValue(forKey: id)
        lock.unlock()
        d?.timeoutItem?.cancel()
        return d?.cont
    }

    /// Create a resident agent from a bare entry specifier resolved against
    /// `roots` (Moddable-style, like `AgentRuntime.runRooted`). Returns nil if
    /// the engine can't be created. The module is imported once, kept alive.
    /// - Parameter installThreads: install the `Thread`/`Service` globals for
    ///   JS-initiated sub-agents. **Must be `false` to be snapshot-capable**
    ///   (`writeSnapshot`) — those globals reference host callbacks not yet in
    ///   the frozen snapshot table (threaded-agent snapshots are a follow-up).
    public init?(
        entryModule: String,
        roots: [(prefix: String, dir: String)],
        makeProvider: @escaping @Sendable () -> (any LLMProvider)?,
        resolveProvider: (@Sendable (String, [String: Any]) -> (any LLMProvider)?)? = nil,
        providerCatalog: [ProviderDescriptor] = [],
        tools: ToolRegistry,
        memory: MemoryStoring,
        tokenBudget: Int? = nil,
        persona: String? = nil,
        installThreads: Bool = true,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let host = Self.makeHost(
            makeProvider: makeProvider, resolveProvider: resolveProvider,
            providerCatalog: providerCatalog, tools: tools, memory: memory,
            tokenBudget: tokenBudget, persona: persona, log: log)
        self.host = host
        guard let engine = XSEngine.tyKaoz(host: host, name: entryModule) else { return nil }
        self.engine = engine
        if installThreads { engine.installThreads() }
        engine.withMachine { _ in JSResource.registerRoots(roots) }
        self.orchestrator = JSResource.path("agent-orchestrator")
        self.legacyHeap = false
        wireDelivery()
        // Import the agent module once — the import resolves within the call's
        // drain, so the orchestrator's agent/agentReady are set (or in flight) by
        // the time this returns.
        if let orchestrator {
            _ = try? engine.callModule(
                orchestrator, export: "loadAgent",
                params: AgentJSON.string(["path": entryModule]))
        }
    }

    /// Restore a resident agent from a snapshot written by `writeSnapshot()`.
    /// The JS heap (loaded module + its state + `__agent`/`__deliver`) comes back
    /// as it was; the agent is NOT re-imported. Host wiring is fresh (new host,
    /// re-registered roots). Only valid for a non-threaded snapshot.
    public init?(
        snapshot: Data,
        roots: [(prefix: String, dir: String)],
        name: String = "resident",
        makeProvider: @escaping @Sendable () -> (any LLMProvider)?,
        resolveProvider: (@Sendable (String, [String: Any]) -> (any LLMProvider)?)? = nil,
        providerCatalog: [ProviderDescriptor] = [],
        tools: ToolRegistry,
        memory: MemoryStoring,
        tokenBudget: Int? = nil,
        persona: String? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let host = Self.makeHost(
            makeProvider: makeProvider, resolveProvider: resolveProvider,
            providerCatalog: providerCatalog, tools: tools, memory: memory,
            tokenBudget: tokenBudget, persona: persona, log: log)
        self.host = host
        xsBridgeTyKaozRegister()   // host table must be registered before reading a snapshot
        guard let engine = XSEngine(snapshot: snapshot, name: name) else { return nil }
        self.engine = engine
        // Point the restored machine's context at THIS host and re-register roots.
        let hostPtr = Unmanaged.passUnretained(host).toOpaque()
        engine.withMachine { machine in
            xsBridgeSetContext(machine, hostPtr)
            JSResource.registerRoots(roots)
        }
        // The agent is NOT re-imported: the restored heap already holds the
        // orchestrator and its state. Which generation, though, decides how this
        // host may drive it — the marker is set by the orchestrator's last line.
        let generation = (try? engine.eval("globalThis.__kaozOrchestrator ?? 0")) ?? "0"
        self.legacyHeap = !(generation == "2" || generation == "3")
        self.orchestrator = self.legacyHeap ? nil : JSResource.path("agent-orchestrator")

        // Nothing in the heap says it was frozen: no module body re-evaluates, so
        // JS cannot notice the restart on its own. Say it explicitly. The counter
        // lives IN the heap, so it keeps counting across successive restores.
        let at = Date().timeIntervalSince1970 * 1000
        let count = (try? engine.eval("""
            globalThis.__kaozRestore = \
            { count: ((globalThis.__kaozRestore && globalThis.__kaozRestore.count) || 0) + 1, \
              at: \(at) }, globalThis.__kaozRestore.count
            """)) ?? "1"

        // Timer handles the restored heap still holds name timers that died with
        // the previous process. Start this host's handles past them, or a stale
        // `host.cancel(oldHandle)` would disarm an unrelated new timer. The base
        // rides in the heap, so it stays disjoint across restores too.
        let base = (try? engine.eval(
            "globalThis.__kaozTimerBase = ((globalThis.__kaozTimerBase) || 0) + 0x10000")) ?? ""
        self.nextTimerHandle = UInt32(base) ?? 1

        // Only a generation-3 heap can route the `restore` delivery; an older one
        // has an orchestrator frozen without that branch.
        if generation == "3" {
            self.restoreInfo = ["count": Int(count) ?? 1, "at": at]
        }
        wireDelivery()
    }

    /// Deliver the one-off `restore` event to a revived agent (its `onRestore`),
    /// so it can re-arm what a snapshot cannot carry — timers above all, which
    /// live in Swift and die with the process. Call it once, before the first real
    /// delivery. Returns the handler's JSON result, or nil when there is nothing
    /// to resume: a host built fresh, or a heap of a generation that cannot route
    /// the event.
    @discardableResult
    public func resumeFromSnapshot(timeout: TimeInterval? = nil) async throws -> String? {
        guard let info = restoreInfo else { return nil }
        restoreInfo = nil
        return try await deliver(kind: "restore", payload: info, timeout: timeout)
    }

    /// Fresh TyKaozHost + (idempotent) sub-agent factory registration.
    private static func makeHost(
        makeProvider: @escaping @Sendable () -> (any LLMProvider)?,
        resolveProvider: (@Sendable (String, [String: Any]) -> (any LLMProvider)?)?,
        providerCatalog: [ProviderDescriptor],
        tools: ToolRegistry,
        memory: MemoryStoring,
        tokenBudget: Int?,
        persona: String?,
        log: @escaping @Sendable (String) -> Void
    ) -> TyKaozHost {
        TyKaozThreads.register { [makeProvider, resolveProvider, providerCatalog, tokenBudget, persona, tools, memory, log] in
            TyKaozHost(
                makeProvider: makeProvider, resolveProvider: resolveProvider,
                providerCatalog: providerCatalog, tools: tools, memory: memory,
                tokenBudget: tokenBudget, persona: persona, log: log)
        }
        return TyKaozHost(
            makeProvider: makeProvider, resolveProvider: resolveProvider,
            providerCatalog: providerCatalog, tools: tools, memory: memory,
            tokenBudget: tokenBudget, persona: persona, log: log)
    }

    /// Serialize the resident agent's JS heap (state included) to bytes. Requires
    /// idle (no in-flight host calls) and a non-threaded engine (see init).
    public func writeSnapshot() throws -> Data {
        try engine.writeSnapshot()
    }

    private func wireDelivery() {
        host.onDeliverResult = { [weak self] id, json, isError in
            guard let self, let cont = self.take(id) else { return }
            if isError { cont.resume(throwing: AgentError.script(json)) }
            else { cont.resume(returning: json) }
        }
        host.onSchedule = { [weak self] delayMs, repeating, payloadJSON in
            self?.arm(delayMs: delayMs, repeating: repeating, payloadJSON: payloadJSON) ?? 0
        }
        host.onCancel = { [weak self] handle in self?.disarm(handle) }
        host.onSnapshotRequest = { [weak self] _ in
            guard let self, self.snapshotSink != nil else { return false }
            self.lock.lock()
            self.checkpointRequested = true
            self.lock.unlock()
            return true
        }
    }

    // MARK: - Checkpointing

    /// Honour a pending checkpoint request, if any. Called after every delivery
    /// settles — the earliest moment the heap is writable, since the JS stack has
    /// unwound by then.
    private func scheduleCheckpointIfNeeded() {
        lock.lock()
        let due = (checkpointRequested || checkpointEveryDelivery) && !closed && snapshotSink != nil
        checkpointRequested = false
        lock.unlock()
        guard due else { return }
        // Serial queue: overlapping deliveries must not race two writes, and a
        // write must never run on the XS thread (see `performCheckpoint`).
        checkpointQueue.async { [weak self] in self?.performCheckpoint() }
    }

    /// Write the heap and hand the bytes to `snapshotSink`. Runs off the engine
    /// thread on purpose: `writeSnapshot` marshals in via the run loop, which only
    /// turns between JS frames, so the heap cannot be mutated mid-write.
    private func performCheckpoint() {
        guard let sink = snapshotSink else { return }
        // A snapshot needs idle: in-flight host calls (an LLM turn, a tool) are
        // parked in Swift, off the heap, and would restore as promises no one can
        // settle. Another delivery may have started meanwhile — let it land.
        let deadline = Date().addingTimeInterval(checkpointSettleTimeout)
        while engine.pendingCount > 0, Date() < deadline { usleep(20_000) }
        let at = Date().timeIntervalSince1970 * 1000
        do {
            let data = try engine.writeSnapshot()
            try sink(data)
            note(ok: true, bytes: data.count, at: at, error: nil)
        } catch {
            host.log("snapshot: \(error.localizedDescription)")
            note(ok: false, bytes: 0, at: at, error: error.localizedDescription)
        }
    }

    /// Publish the outcome to JS (`host.lastSnapshot()`). Written *after* the
    /// heap is frozen, so it describes this process — the restored heap will
    /// carry the record of the checkpoint before the one that revived it, which
    /// is the honest reading.
    private func note(ok: Bool, bytes: Int, at: Double, error: String?) {
        let payload = AgentJSON.string([
            "ok": ok, "bytes": bytes, "at": at, "error": error ?? NSNull(),
        ])
        _ = try? engine.eval("globalThis.__kaozSnapshot = \(payload)")
    }

    /// Arm a timer that delivers a `tick` (the payload) after / every `delayMs`.
    /// Returns a handle for `disarm`. Runs the tick off a background queue → the
    /// engine thread, like any delivery.
    private func arm(delayMs: Double, repeating: Bool, payloadJSON: String) -> UInt32 {
        let payload: Any = payloadJSON.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
        } ?? NSNull()
        let interval = max(0, delayMs) / 1000.0
        let handle: UInt32 = {
            lock.lock(); defer { lock.unlock() }
            let v = nextTimerHandle; nextTimerHandle &+= 1; return v
        }()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        if repeating {
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
        } else {
            timer.schedule(deadline: .now() + interval, leeway: .milliseconds(50))
        }
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !repeating { self.disarm(handle) }   // one-shot: fire once
            Task { try? await self.deliver(kind: "tick", payload: payload) }
        }
        lock.lock()
        if closed { lock.unlock(); timer.cancel(); return 0 }
        timers[handle] = timer
        lock.unlock()
        timer.resume()
        return handle
    }

    private func disarm(_ handle: UInt32) {
        lock.lock()
        let timer = timers.removeValue(forKey: handle)
        lock.unlock()
        timer?.cancel()
    }

    /// Deliver one event to the resident agent and await its handler's JSON
    /// result. `kind`: `"message"` (→ onMessage/run), `"event"` (→ onEvent),
    /// `"tick"` (→ onTick). Throws `AgentError.script` if the handler rejects.
    ///
    /// `timeout` (cooperative): if the handler doesn't settle in time, this call
    /// throws `AgentError.timeout` and stops waiting — but the JS keeps running
    /// (there is no way to interrupt a running eval; a hard watchdog is a
    /// follow-up). The engine survives, ready for the next delivery.
    @discardableResult
    public func deliver(
        kind: String = "message", payload: Any? = nil, timeout: TimeInterval? = nil
    ) async throws -> String {
        let id: UInt32 = {
            lock.lock(); defer { lock.unlock() }
            let v = nextId; nextId &+= 1; return v
        }()
        let inputJSON = AgentJSON.string(payload ?? NSNull())
        // Runs on the throwing paths too (timeout, script error): a checkpoint the
        // agent asked for before it failed is still worth taking.
        defer { scheduleCheckpointIfNeeded() }
        return try await withCheckedThrowingContinuation { cont in
            let timeoutItem = timeout.map { _ in
                DispatchWorkItem { [weak self] in
                    self?.take(id)?.resume(throwing: AgentError.timeout)
                }
            }
            lock.lock()
            if closed {
                lock.unlock()
                cont.resume(throwing: AgentError.script("agent host closed"))
                return
            }
            pending[id] = Delivery(cont: cont, timeoutItem: timeoutItem)
            lock.unlock()
            if let timeout, let timeoutItem {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
            }
            // Kicks off the handler on the XS thread; the promise settles later
            // via host.__deliverResult → onDeliverResult → this continuation.
            do {
                // The payload rides in as the native global `__xsbInput` (not
                // spliced into source), so a document-sized message can't
                // overflow the XS lexer's parser buffer. __deliver JSON.parses
                // it synchronously at its top, before this eval returns.
                if let orchestrator {
                    _ = try engine.callModule(
                        orchestrator, export: "deliver",
                        params: AgentJSON.string([
                            "kind": kind, "deliveryId": Int(id), "input": payload ?? NSNull(),
                        ]))
                } else {
                    // Legacy heap: drive the globals it came back with.
                    _ = try engine.eval(
                        "__deliver(\(AgentJSON.jsLiteral(kind)), \(id), __xsbInput)",
                        input: inputJSON)
                }
            } catch {
                take(id)?.resume(throwing: error)
            }
        }
    }

    /// Number of async host calls still in flight on this engine (0 == idle).
    public var pendingCount: Int { engine.pendingCount }

    /// Drain to idle, fail any still-pending deliveries, and stop accepting new
    /// ones. The engine itself is released when this `AgentHost` is deallocated
    /// (its deinit joins the XS thread, so drop the last reference off it).
    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let orphans = Array(pending.values)
        pending.removeAll()
        let armed = Array(timers.values)
        timers.removeAll()
        lock.unlock()
        for t in armed { t.cancel() }
        for d in orphans {
            d.timeoutItem?.cancel()
            d.cont.resume(throwing: AgentError.script("agent host closed"))
        }
        host.onDeliverResult = nil
        host.onSchedule = nil
        host.onCancel = nil
        host.onSnapshotRequest = nil
        let engine = self.engine
        DispatchQueue.global().async {
            engine.runUntilIdle(timeout: 2)
            withExtendedLifetime(engine) {}
        }
    }

    deinit {
        // A DispatchSourceTimer must be cancelled before release.
        for t in timers.values { t.cancel() }
    }
}
