import Foundation

/// Meta (Muse Spark), over its OpenAI-compatible Model API.
///
/// Owns the endpoint so the settings UI doesn't keep its own copy of the URL.
public struct MetaProvider: LLMProvider {
    public let id: String = "meta"
    public let displayName: String = "Meta"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.meta.ai/v1")!
    public static let defaultModel = "muse-spark-1.3"

    public init(
        apiKey: String, model: String = MetaProvider.defaultModel,
        baseURL: URL = MetaProvider.baseURL, session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your Meta API key in Settings.")
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

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        client.chat(model: model, messages: messages, tools: tools)
    }
}
