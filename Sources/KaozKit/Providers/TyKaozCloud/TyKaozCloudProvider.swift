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

    public static let baseURL = URL(string: "https://odzgcorc9h.execute-api.eusc-de-east-1.amazonaws.eu/prod/v1")!
    public static let defaultModel = "amazon.nova-lite-v1:0"

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

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        client.chat(model: model, messages: messages, tools: tools)
    }
}
