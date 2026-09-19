import Foundation

/// Scaleway Generative APIs, over their OpenAI-compatible endpoint.
///
/// Owns the endpoint so the settings UI doesn't keep its own copy of the URL.
/// The default URL serves the account's default project; the key is an IAM
/// secret key.
public struct ScalewayProvider: LLMProvider {
    public let id: String = "scaleway"
    public let displayName: String = "Scaleway"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.scaleway.ai/v1")!
    public static let defaultModel = "mistral-small-3.2-24b-instruct-2506"

    public init(
        apiKey: String, model: String = ScalewayProvider.defaultModel,
        baseURL: URL = ScalewayProvider.baseURL, session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Enter your Scaleway secret key in Settings.")
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
