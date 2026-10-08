import Foundation

public struct MistralProvider: LLMProvider {
    public let id: String = "mistral"
    public let displayName: String = "Mistral"

    public let apiKey: String
    public let model: String
    /// `reasoning_effort` for a model that reasons; nil leaves the model's
    /// default, which thinks.
    public let reasoningEffort: String?

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.mistral.ai/v1")!

    public init(apiKey: String, model: String, reasoningEffort: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.client = OpenAICompatibleClient(
            baseURL: Self.baseURL, apiKey: apiKey, session: session, reasoningAsBlocks: true)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your Mistral API key in Settings.")
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
        client.chat(model: model, messages: messages, tools: tools, reasoningEffort: reasoningEffort)
    }

    /// The efforts a Mistral model accepts, for one its `/v1/models` marks as
    /// reasoning: GLM 5.3 takes `low`, `high` or `max`; Mistral's own models
    /// only `none` or `high` (docs.mistral.ai, Reasoning). Their default thinks.
    public static func reasoning(for model: OpenAICompatibleModelsResponse.Model)
        -> OpenAICompatibleModelsResponse.Reasoning? {
        guard model.capabilities?.reasoning == true else { return nil }
        return model.id.lowercased().contains("glm")
            ? .init(values: ["low", "high", "max"], defaultValue: "high")
            : .init(values: ["none", "high"], defaultValue: "high")
    }
}
