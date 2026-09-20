import Foundation

public struct AnthropicProvider: LLMProvider {
    public let id: String = "anthropic"
    public let displayName: String = "Anthropic"

    public let apiKey: String
    public let model: String
    /// Output ceiling for one turn. On models that always think (Fable 5.1)
    /// it bounds thinking and answer together, so the client's 4096 default
    /// can leave nothing for the answer; a caller writing prose raises it.
    public let maxTokens: Int?
    /// `output_config.effort` — low … max. Omitted when nil: Haiku 4.5 rejects
    /// the field, so it must stay opt-in per call.
    public let effort: String?

    private let client: AnthropicClient

    public init(apiKey: String, model: String, maxTokens: Int? = nil, effort: String? = nil,
                session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
        self.client = AnthropicClient(apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your Anthropic API key in Settings.")
        }
        do {
            let models = try await client.listModels()
            guard models.contains(where: { $0.id == model }) else {
                return .unavailable(reason: "Model \"\(model)\" is not accessible with this key.")
            }
            return .ready
        } catch let error as AnthropicClientError {
            return .unavailable(reason: error.errorDescription ?? "Erreur.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        client.chat(model: model, messages: messages, tools: tools,
                    maxTokens: maxTokens ?? AnthropicClient.defaultMaxTokens, effort: effort)
    }
}
