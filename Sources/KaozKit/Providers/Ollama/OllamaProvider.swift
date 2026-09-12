import Foundation

public struct OllamaProvider: LLMProvider {
    public let id: String = "ollama"
    public let displayName: String = "Ollama"

    public let baseURL: URL
    public let model: String

    private let client: OllamaClient

    public init(baseURL: URL, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.client = OllamaClient(baseURL: baseURL, session: session)
    }

    public func availability() async -> ProviderAvailability {
        do {
            let models = try await client.listModels()
            guard !models.isEmpty else {
                return .unavailable(reason: "The server offers no model.")
            }
            guard models.contains(where: { $0.name == model }) else {
                return .unavailable(reason: "Model \"\(model)\" is not installed on this server.")
            }
            return .ready
        } catch let error as OllamaClientError {
            return .unavailable(reason: error.errorDescription ?? "Erreur inconnue.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        client.chat(model: model, messages: messages, tools: tools)
    }
}
