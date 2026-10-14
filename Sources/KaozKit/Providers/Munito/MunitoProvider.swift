import Foundation

/// Munito (open models, Munito AI France), over its OpenAI-compatible
/// endpoint. The EU host keeps processing in the European Union.
///
/// Owns the endpoint so the settings UI doesn't keep its own copy of the URL.
public struct MunitoProvider: LLMProvider {
    public let id: String = "munito"
    public let displayName: String = "Munito"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.eu.munito.ai/inference/v1")!
    public static let defaultModel = "mistralai/mistral-small-4-119b-2603"

    public init(
        apiKey: String, model: String = MunitoProvider.defaultModel,
        baseURL: URL = MunitoProvider.baseURL, session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your Munito API key in Settings.")
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
