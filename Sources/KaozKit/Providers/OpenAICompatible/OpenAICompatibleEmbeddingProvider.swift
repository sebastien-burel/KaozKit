import Foundation

/// Embeddings from any provider that speaks OpenAI's `/embeddings`: OpenAI,
/// Google's compatible route, Mistral, Qwen, Infomaniak, Scaleway, TyKaoz
/// Cloud Paris, a local server. The wiki sends each section of its pages
/// here, and each search.
///
/// Vectors come back normalised: the index ranks by L2 distance, which
/// orders like cosine only for unit vectors — and not every provider
/// normalises, notably once a vector has been shortened.
public struct OpenAICompatibleEmbeddingProvider: EmbeddingProvider {
    /// The app provider this runs through (`openai`, `tykaozCloudParis`…).
    public let id: String
    public let modelID: String
    public let dimension: Int
    /// Sent as `dimensions` to a model that can shorten its vectors; nil
    /// leaves the model's own length.
    public let requestedDimensions: Int?

    private let client: OpenAICompatibleClient
    private let counter = TokenCounter()

    public init(
        id: String, baseURL: URL, apiKey: String, modelID: String, dimension: Int,
        requestedDimensions: Int? = nil, extraHeaders: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.id = id
        self.modelID = modelID
        self.dimension = dimension
        self.requestedDimensions = requestedDimensions
        self.client = OpenAICompatibleClient(
            baseURL: baseURL, apiKey: apiKey, session: session, extraHeaders: extraHeaders)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        let result = try await client.embed(model: modelID, inputs: texts, dimensions: requestedDimensions)
        guard result.vectors.count == texts.count else {
            throw OpenAICompatibleError.decoding(
                message: "\(result.vectors.count) vectors for \(texts.count) texts")
        }
        if let tokens = result.promptTokens { counter.add(tokens) }
        return result.vectors.map(Self.normalised)
    }

    public var tokensUsed: Int? { counter.total }

    static func normalised(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

/// Shared by every copy of a provider value, so the count survives the
/// struct being passed around.
private final class TokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func add(_ tokens: Int) { lock.withLock { value += tokens } }
    var total: Int { lock.withLock { value } }
}
