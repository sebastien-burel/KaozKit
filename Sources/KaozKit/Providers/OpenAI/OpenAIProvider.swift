import Foundation

public struct OpenAIProvider: LLMProvider {
    public let id: String = "openai"
    public let displayName: String = "OpenAI"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.openai.com/v1")!

    private let responses: OpenAIResponsesClient?

    /// - Parameter reasoningEffort: forwarded to `/v1/responses` for the
    ///   reasoning families. nil lets the server choose.
    public init(
        apiKey: String, model: String, session: URLSession = .shared,
        reasoningEffort: String? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(
            baseURL: Self.baseURL, apiKey: apiKey, session: session)
        self.responses = Self.reasons(model)
            ? OpenAIResponsesClient(
                baseURL: Self.baseURL, apiKey: apiKey, session: session,
                reasoningEffort: reasoningEffort)
            : nil
    }

    /// The reasoning families go to `/v1/responses`; everything else keeps
    /// `/v1/chat/completions`.
    ///
    /// On chat completions these models reject function tools outright — they
    /// default `reasoning_effort` to `"medium"` server-side, so merely sending
    /// tools returns a 400, and the only way through is to disable reasoning.
    /// The responses surface takes both, so routing there is what makes an
    /// agentic turn possible at all, not a preference.
    ///
    /// A prefix test is the only signal available before the first call. It
    /// needs a new entry whenever OpenAI ships a reasoning family under a name
    /// this doesn't match — the symptom would be that 400 coming back.
    static func reasons(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3")
            || m.hasPrefix("o4")
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Renseignez votre clé API OpenAI dans les réglages.")
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
        if let responses {
            return responses.chat(model: model, messages: messages, tools: tools)
        }
        return client.chat(model: model, messages: messages, tools: tools)
    }
}
