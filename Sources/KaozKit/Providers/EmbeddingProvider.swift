import Foundation

/// Separate from `LLMProvider` because chat and embedding capabilities
/// don't always coexist (Apple Intelligence and Anthropic ship no
/// embedding API). Conformers wire themselves up explicitly in
/// `AppSettings`. Phase 5 of PLAN_TYKAOZ_WIKI introduces the first
/// real conformer (Ollama).
public protocol EmbeddingProvider: Sendable {
    var id: String { get }
    var modelID: String { get }
    /// Output vector length. Locks `vec_chunks.embedding FLOAT[N]` —
    /// changing models means dropping and recreating that table.
    var dimension: Int { get }
    /// Embeds a batch of texts. Returns vectors in the same order;
    /// throws on transport or model errors.
    func embed(_ texts: [String]) async throws -> [[Float]]
    /// Tokens billed so far by a provider that counts them; nil for one
    /// that runs locally or does not say.
    var tokensUsed: Int? { get }
}

extension EmbeddingProvider {
    public var tokensUsed: Int? { nil }
}
