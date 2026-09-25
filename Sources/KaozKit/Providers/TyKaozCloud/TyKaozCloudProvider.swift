import Foundation

/// TyKaoz Cloud: Haruni's endpoints, over an OpenAI-compatible API. One key
/// opens both and spends one budget. The AWS European Sovereign Cloud
/// (Brandenburg) serves the Amazon Nova models; Paris serves Scaleway's.
/// The requests are processed in two countries, so the app shows two
/// providers, and each value of this type talks to one endpoint.
///
/// Owns the endpoints so the settings UI doesn't keep its own copy of the URLs.
public struct TyKaozCloudProvider: LLMProvider {
    public let id: String
    public let displayName: String

    public let apiKey: String
    public let model: String

    /// Whether the endpoint returns the answer whole, as the sovereign
    /// cloud does: it has no streaming transport yet.
    private let buffered: Bool
    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://cloud.tykaoz.bzh/v1")!
    public static let parisBaseURL = URL(string: "https://fr.cloud.tykaoz.bzh/v1")!
    public static let defaultModel = "Nova Lite"
    public static let parisDefaultModel = "Mistral Small 3.2"

    public init(
        apiKey: String, model: String = TyKaozCloudProvider.defaultModel,
        baseURL: URL = TyKaozCloudProvider.baseURL, session: URLSession = .shared
    ) {
        let paris = baseURL == Self.parisBaseURL
        self.id = paris ? "tykaozCloudParis" : "tykaozCloud"
        self.displayName = paris ? "TyKaoz · France" : "TyKaoz · Germany"
        self.apiKey = apiKey
        self.model = model
        self.buffered = !paris
        self.client = OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    /// How much of the month's allowance a key has spent. The endpoint
    /// gives a ratio, never an amount: what the subscription covers is its
    /// business. `ratio` is nil for a key without a budget.
    public struct Usage: Decodable, Sendable, Equatable {
        public let period: String
        public let ratio: Double?
        public let resetsAt: Date

        enum CodingKeys: String, CodingKey { case period, ratio, resetsAt = "resets_at" }
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
    /// answer, latency included. Paris streams, and its metrics stand.
    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        let source = client.chat(model: model, messages: messages, tools: tools)
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
