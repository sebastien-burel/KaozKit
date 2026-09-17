import Foundation

/// MiniMax, over its OpenAI-compatible endpoint.
///
/// Owns the endpoint so the settings UI doesn't keep its own copy of the URL.
public struct MiniMaxProvider: LLMProvider {
    public let id: String = "minimax"
    public let displayName: String = "MiniMax"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.minimax.io/v1")!
    public static let defaultModel = "MiniMax-M2"

    public init(
        apiKey: String, model: String = MiniMaxProvider.defaultModel,
        baseURL: URL = MiniMaxProvider.baseURL, session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your MiniMax API key in Settings.")
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
