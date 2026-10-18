import Foundation

/// TyKaoz Cloud: Haruni's endpoints, over an OpenAI-compatible API. One key
/// opens all three and spends one budget. The AWS European Sovereign Cloud
/// (Brandenburg) serves the Amazon Nova models; Paris serves Scaleway's;
/// Switzerland serves Infomaniak's, through Paris. The requests are
/// processed in three countries, so the app shows three providers, and
/// each value of this type talks to one endpoint.
///
/// Owns the endpoints so the settings UI doesn't keep its own copy of the URLs.
public struct TyKaozCloudProvider: LLMProvider {
    public let id: String
    public let displayName: String

    public let apiKey: String
    public let model: String
    /// Sent as `reasoning_effort`; nil leaves the choice to the server.
    public let reasoningEffort: String?

    /// Whether the endpoint returns the answer whole, as the sovereign
    /// cloud does: it has no streaming transport yet.
    private let buffered: Bool
    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://cloud.tykaoz.bzh/v1")!
    public static let parisBaseURL = URL(string: "https://fr.cloud.tykaoz.bzh/v1")!
    public static let swissBaseURL = URL(string: "https://ch.cloud.tykaoz.bzh/v1")!
    public static let defaultModel = "Nova Lite"
    public static let parisDefaultModel = "Mistral Small 3.2"
    public static let swissDefaultModel = "Mistral Small 4"

    public init(
        apiKey: String, model: String = TyKaozCloudProvider.defaultModel,
        baseURL: URL = TyKaozCloudProvider.baseURL, reasoningEffort: String? = nil,
        session: URLSession = .shared
    ) {
        switch baseURL {
        case Self.parisBaseURL:
            (id, displayName) = ("tykaozCloudParis", "TyKaoz · France")
        case Self.swissBaseURL:
            (id, displayName) = ("tykaozCloudSwiss", "TyKaoz · Switzerland")
        default:
            (id, displayName) = ("tykaozCloud", "TyKaoz · Germany")
        }
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.buffered = id == "tykaozCloud"
        self.client = OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    /// How much of the month's allowance a key has spent. The endpoint
    /// gives a ratio, never an amount: what the subscription covers is its
    /// business. `ratio` is nil for a key without a budget. A key of a
    /// subscription also gets its `credits`.
    public struct Usage: Decodable, Sendable, Equatable {
        public let period: String
        /// Deprecated by `usagePercent`, with `credits`.
        public let ratio: Double?
        public let resetsAt: Date
        public let credits: Credits?
        /// The share of the plan used this month, a whole percent from 0 to
        /// 100, for all regions together — computed by the service, which
        /// alone knows the plan. Nil from a service not yet updated.
        public let usagePercent: Int?
        /// "<1" for a use too small to show as a percent, nil otherwise.
        public let usageDisplay: String?
        /// When the month renews.
        public let renewsAt: Date?
        /// The plan's name, « Plus » or « Pro ».
        public let planName: String?
        /// Each top-up on sale, its size as a share of the plan's month.
        public let topups: [Topup]?
        /// The top-ups' balance, in share of a month, not capped at 100.
        public let topupReservePercent: Int?
        /// "<1" for a reserve too small to show as a percent, nil otherwise.
        public let topupReserveDisplay: String?

        enum CodingKeys: String, CodingKey {
            case period, ratio, credits, topups, resetsAt = "resets_at", usagePercent = "usage_percent",
                 usageDisplay = "usage_display", renewsAt = "renews_at", planName = "plan_name",
                 topupReservePercent = "topup_reserve_percent", topupReserveDisplay = "topup_reserve_display"
        }
    }

    /// A top-up the service sells: its offer, as the licence service names
    /// it, and what it adds, as a percent of the plan's month.
    public struct Topup: Decodable, Sendable, Equatable {
        public let offer: String
        public let percent: Int
    }

    /// What a subscription has left, in credits: of the month (`cycle`,
    /// below zero when the month overspent) and of the top-ups, out of what
    /// a month grants; and when the month renews.
    public struct Credits: Decodable, Sendable, Equatable {
        public let remaining: Double
        public let cycle: Double
        public let topup: Double
        public let month: Double?
        public let renewsAt: Date?

        enum CodingKeys: String, CodingKey { case remaining, cycle, topup, month, renewsAt = "renews_at" }
    }

    public static func usage(apiKey: String, session: URLSession = .shared) async throws -> Usage {
        var request = URLRequest(url: baseURL.appending(path: "/usage"))
        request.timeoutInterval = 10
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAICompatibleError.network(message: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.network(message: "non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleError.http(status: http.statusCode, body: String(data: data, encoding: .utf8))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Usage.self, from: data)
        } catch {
            throw OpenAICompatibleError.decoding(message: error.localizedDescription)
        }
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your TyKaoz key in Settings.")
        }
        do {
            let models = try await client.listModels()
            guard models.contains(where: { $0.id == model }) else {
                return .unavailable(reason: "Model \"\(model)\" is not accessible with this key.")
            }
            return .ready
        } catch let error as OpenAICompatibleError {
            return .unavailable(reason: error.errorDescription ?? "Erreur.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// From the sovereign cloud the answer arrives whole, so the client's
    /// first-to-last-token window only clocks the download and reads as an
    /// absurd speed. The throughput shown there is the whole round trip
    /// instead: output tokens over the time from request to complete
    /// answer, latency included. Paris and Switzerland stream, and their
    /// metrics stand.
    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        let source = client.chat(
            model: model, messages: messages, tools: tools, reasoningEffort: reasoningEffort)
        let buffered = buffered
        return AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    for try await event in source {
                        if buffered, case .metrics(let measured) = event {
                            var metrics = GenerationMetrics()
                            metrics.promptTokens = measured.promptTokens
                            metrics.completionTokens = measured.completionTokens
                            let elapsed = start.duration(to: clock.now).components
                            metrics.generationDuration = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
                            continuation.yield(.metrics(metrics))
                        } else {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
