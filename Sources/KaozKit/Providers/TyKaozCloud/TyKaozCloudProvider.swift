import Foundation

/// TyKaoz Cloud: Haruni's endpoints, over an OpenAI-compatible API. The
/// AWS European Sovereign Cloud serves the Amazon Nova models; Paris
/// serves Scaleway's. One key opens both and spends one budget; each
/// endpoint lists only its own models, so the provider asks both and
/// sends every model to the endpoint that listed it.
///
/// Owns the endpoints so the settings UI doesn't keep its own copy of the URLs.
public struct TyKaozCloudProvider: LLMProvider {
    public let id: String = "tykaozCloud"
    public let displayName: String = "TyKaoz"

    public let apiKey: String
    public let model: String

    private let session: URLSession

    public static let baseURL = URL(string: "https://cloud.tykaoz.bzh/v1")!
    public static let parisBaseURL = URL(string: "https://fr.cloud.tykaoz.bzh/v1")!
    public static let defaultModel = "TyKaoz Lite"

    public init(
        apiKey: String, model: String = TyKaozCloudProvider.defaultModel,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    /// Every model the key can use, from both endpoints, remembering which
    /// endpoint serves which. An endpoint that fails is left out, so Paris
    /// being down still leaves Nova; only both failing is an error.
    public static func listModels(apiKey: String, session: URLSession = .shared) async throws -> [String] {
        @Sendable func list(_ url: URL) async -> Result<[String], any Error> {
            do {
                let client = OpenAICompatibleClient(baseURL: url, apiKey: apiKey, session: session)
                return .success(try await client.listModels().map(\.id))
            } catch {
                return .failure(error)
            }
        }
        async let sovereign = list(baseURL)
        async let paris = list(parisBaseURL)
        let served = try endpoints(from: [(baseURL, await sovereign), (parisBaseURL, await paris)])
        await TyKaozCloudDirectory.shared.replace(served)
        return served.keys.sorted()
    }

    /// Which endpoint serves which model, from each endpoint's list. The
    /// first endpoint to list a name keeps it; the first error is thrown
    /// only when no endpoint answered.
    static func endpoints(from lists: [(URL, Result<[String], any Error>)]) throws -> [String: URL] {
        var served: [String: URL] = [:]
        var firstError: (any Error)?
        var answered = false
        for (url, result) in lists {
            switch result {
            case .success(let ids):
                answered = true
                for id in ids where served[id] == nil { served[id] = url }
            case .failure(let error):
                firstError = firstError ?? error
            }
        }
        if !answered, let firstError { throw firstError }
        return served
    }

    /// The endpoint serving this provider's model: remembered from the last
    /// listing, or listed now. The sovereign cloud when nobody claims it,
    /// so an unknown model gets that endpoint's own "not found".
    private func endpoint() async throws -> URL {
        if let url = await TyKaozCloudDirectory.shared.url(for: model) { return url }
        _ = try await Self.listModels(apiKey: apiKey, session: session)
        return await TyKaozCloudDirectory.shared.url(for: model) ?? Self.baseURL
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
            let models = try await Self.listModels(apiKey: apiKey, session: session)
            guard models.contains(model) else {
                return .unavailable(reason: "Model \"\(model)\" is not accessible with this key.")
            }
            return .ready
        } catch let error as OpenAICompatibleError {
            return .unavailable(reason: error.errorDescription ?? "Erreur.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    /// From the sovereign cloud the answer arrives whole — it has no
    /// streaming transport for the endpoint yet — so the client's
    /// first-to-last-token window only clocks the download and reads as an
    /// absurd speed. The throughput shown there is the whole round trip
    /// instead: output tokens over the time from request to complete
    /// answer, latency included. Paris streams, and its metrics stand.
    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = try await endpoint()
                    let source = OpenAICompatibleClient(baseURL: url, apiKey: apiKey, session: session)
                        .chat(model: model, messages: messages, tools: tools)
                    let buffered = url == Self.baseURL
                    let clock = ContinuousClock()
                    let start = clock.now
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

/// Which endpoint serves which model, from the last listing. Shared by
/// every provider value, since the app builds one per turn.
private actor TyKaozCloudDirectory {
    static let shared = TyKaozCloudDirectory()
    private var served: [String: URL] = [:]

    func replace(_ served: [String: URL]) { self.served = served }
    func url(for model: String) -> URL? { served[model] }
}
