import Foundation

/// Xiaomi MiMo, over its OpenAI-compatible endpoint.
///
/// MiMo also publishes an Anthropic-shaped endpoint (`/anthropic`) and a
/// China token-plan host (`token-plan-cn.xiaomimimo.com`); both speak the same
/// models, so only the default OpenAI surface is wired here — point `baseURL`
/// elsewhere to use another one.
public struct MiMoProvider: LLMProvider {
    public let id: String = "mimo"
    public let displayName: String = "Xiaomi MiMo"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.xiaomimimo.com/v1")!

    public init(
        apiKey: String, model: String,
        baseURL: URL = MiMoProvider.baseURL, session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        // MiMo's reference is the OpenAI SDK (Bearer), but its own docs specify
        // an `api-key` header. Send both: the unused one is ignored.
        self.client = OpenAICompatibleClient(
            baseURL: baseURL, apiKey: apiKey, session: session,
            extraHeaders: ["api-key": apiKey.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Renseignez votre clé API Xiaomi MiMo dans les réglages.")
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
