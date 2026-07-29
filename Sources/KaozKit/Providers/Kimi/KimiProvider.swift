import Foundation

/// Kimi (Moonshot AI), over its OpenAI-compatible endpoint.
///
/// Owns the endpoint so the JS variant and the settings UI stop each keeping
/// their own copy of the URL.
public struct KimiProvider: LLMProvider {
    public let id: String = "kimi"
    public let displayName: String = "Kimi (Moonshot)"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.moonshot.ai/v1")!
    public static let defaultModel = "kimi-k3"

    public init(
        apiKey: String, model: String = KimiProvider.defaultModel,
        baseURL: URL = KimiProvider.baseURL, session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Renseignez votre clé API Moonshot (Kimi) dans les réglages.")
        }
        do {
            let models = try await client.listModels()
            guard models.contains(where: { $0.id == model }) else {
                return .unavailable(reason: "Le modèle « \(model) » n'est pas accessible avec cette clé.")
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
