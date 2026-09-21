import Foundation

/// TyKaoz Cloud: Haruni's endpoint in the AWS European Sovereign Cloud,
/// serving the Amazon Nova models over an OpenAI-compatible API. Keys are
/// issued by Haruni; the endpoint counts tokens per key.
///
/// Owns the endpoint so the settings UI doesn't keep its own copy of the URL.
public struct TyKaozCloudProvider: LLMProvider {
    public let id: String = "tykaozCloud"
    public let displayName: String = "TyKaoz Cloud"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://cloud.tykaoz.bzh/v1")!
    public static let defaultModel = "TyKaoz Lite"

    public init(
        apiKey: String, model: String = TyKaozCloudProvider.defaultModel,
        baseURL: URL = TyKaozCloudProvider.baseURL, session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your TyKaoz Cloud key in Settings.")
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

    /// The answer arrives whole — the sovereign cloud has no streaming
    /// transport for the endpoint yet — so the client's first-to-last-token
    /// window only clocks the download and reads as an absurd speed. The
    /// throughput shown is the whole round trip instead: output tokens
    /// over the time from request to complete answer, latency included.
    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        let source = client.chat(model: model, messages: messages, tools: tools)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    for try await event in source {
                        if case .metrics(let measured) = event {
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
