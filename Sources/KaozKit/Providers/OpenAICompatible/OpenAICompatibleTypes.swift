import Foundation

/// Decoded shape of one streamed chunk from the OpenAI-compatible
/// `/v1/chat/completions` API (used by OpenAI, Mistral, DeepSeek). Both
/// content text and partial tool-call payloads can appear, sometimes
/// together.
public struct OpenAICompatibleChunk: Decodable {
    public struct Choice: Decodable {
        public struct Delta: Decodable {
            public let content: String?
            public let toolCalls: [ToolCallDelta]?
            public let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
                case reasoningContent = "reasoning_content"
            }

            /// `content` is a string, or — for Mistral's reasoning models — a
            /// list of blocks: `text` blocks are the answer, `thinking` blocks
            /// (themselves holding text blocks) the reasoning.
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                toolCalls = try c.decodeIfPresent([ToolCallDelta].self, forKey: .toolCalls)
                var reasoning = try c.decodeIfPresent(String.self, forKey: .reasoningContent)
                if let text = try? c.decodeIfPresent(String.self, forKey: .content) {
                    content = text
                } else if let blocks = try? c.decodeIfPresent([ContentBlock].self, forKey: .content) {
                    let text = blocks.compactMap(\.text).joined()
                    let thinking = blocks.flatMap { $0.thinking ?? [] }.compactMap(\.text).joined()
                    content = text.isEmpty ? nil : text
                    if !thinking.isEmpty { reasoning = (reasoning ?? "") + thinking }
                } else {
                    content = nil
                }
                reasoningContent = reasoning
            }
        }

        struct ContentBlock: Decodable {
            let type: String?
            let text: String?
            let thinking: [ContentBlock]?
        }

        public struct ToolCallDelta: Decodable {
            public let index: Int?
            public let id: String?
            /// "function" in the current API; carried as-is for forwards
            /// compatibility but we don't switch on it.
            public let type: String?
            public let function: FunctionDelta?
        }

        public struct FunctionDelta: Decodable {
            public let name: String?
            public let arguments: String?
        }

        /// Optional: some providers (e.g. Qwen reasoning models) emit
        /// choices with no `delta` on certain chunks. A missing delta must
        /// not abort the whole stream.
        public let delta: Delta?
        public let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    /// Token accounting. Present only when the request opts in via
    /// `stream_options.include_usage`; it then arrives in a trailing chunk
    /// (with `choices` empty) just before `[DONE]`. Some servers also inline
    /// it on the final content chunk.
    public struct Usage: Decodable {
        public let promptTokens: Int?
        public let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    /// Optional: a trailing usage-only chunk, or an occasional metadata
    /// chunk, can arrive without any `choices` key. Decode it as empty
    /// rather than throwing.
    public let choices: [Choice]?
    public let usage: Usage?
}

public struct OpenAICompatibleModelsResponse: Decodable {
    public struct Model: Decodable, Identifiable, Hashable {
        public let id: String
        /// How far the model can be asked to reason, when the server says so
        /// (TyKaoz Cloud does). Absent everywhere else.
        public let reasoning: Reasoning?
        /// "embedding" for a model served on `/embeddings`, when the server
        /// says so (TyKaoz Cloud does); nil means chat, or unknown.
        public let kind: String?
        /// The vector lengths an embedding model can return, when the
        /// server says so.
        public let dimensions: Dimensions?
        /// What the model costs in credits, when the server says so
        /// (TyKaoz Cloud does). Never an amount of money.
        public let pricing: Pricing?
        /// What the model can do, when the server says so (Mistral does).
        public let capabilities: Capabilities?
    }

    /// Mistral's model capabilities; only whether the model reasons is read.
    public struct Capabilities: Decodable, Hashable, Sendable {
        public let reasoning: Bool?
    }

    /// A model's price in credits per million tokens, and its band:
    /// `econome`, `standard` or `premium`.
    public struct Pricing: Codable, Hashable, Sendable {
        public let label: String
        public let inputCreditsPerMillion: Double
        public let outputCreditsPerMillion: Double

        public init(label: String, inputCreditsPerMillion: Double, outputCreditsPerMillion: Double) {
            self.label = label
            self.inputCreditsPerMillion = inputCreditsPerMillion
            self.outputCreditsPerMillion = outputCreditsPerMillion
        }

        enum CodingKeys: String, CodingKey {
            case label
            case inputCreditsPerMillion = "input_credits_per_m"
            case outputCreditsPerMillion = "output_credits_per_m"
        }
    }

    /// The lengths an embedding model returns, and the one it defaults to.
    public struct Dimensions: Codable, Hashable, Sendable {
        public let values: [Int]
        public let defaultValue: Int

        public init(values: [Int], defaultValue: Int) {
            self.values = values
            self.defaultValue = defaultValue
        }

        enum CodingKeys: String, CodingKey { case values, defaultValue = "default" }
    }

    /// The `reasoning_effort` values a model accepts, and the one the
    /// server applies when the request carries none.
    public struct Reasoning: Codable, Hashable, Sendable {
        public let values: [String]
        public let defaultValue: String

        public init(values: [String], defaultValue: String) {
            self.values = values
            self.defaultValue = defaultValue
        }

        enum CodingKeys: String, CodingKey { case values, defaultValue = "default" }
    }
    public let data: [Model]
}
