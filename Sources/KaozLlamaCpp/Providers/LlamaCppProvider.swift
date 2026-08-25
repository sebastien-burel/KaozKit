import Foundation
import KaozKit

/// `LLMProvider` running a GGUF model in-process through llama.cpp.
///
/// The sibling of `MLXLLMProvider`, and deliberately its mirror image: cheap and
/// stateless on its own, delegating the model to a cached `LlamaChatActor`. It
/// exists because MLX trails llama.cpp on new architectures — the model that
/// mlx-swift-lm cannot load yet usually has a GGUF that runs today.
public struct LlamaCppProvider: LLMProvider {
    public let id: String = "llamacpp"
    public let displayName: String = "Sur ce Mac (llama.cpp)"
    /// Absolute path to the `.gguf` file.
    public let modelPath: String
    /// Optional multimodal projector (`mmproj-*.gguf`) for vision models.
    public let mmprojPath: String?

    public init(modelPath: String, mmprojPath: String? = nil) {
        self.modelPath = modelPath
        self.mmprojPath = mmprojPath
    }

    public func availability() async -> ProviderAvailability {
        // Unlike MLX there is no store to consult: a GGUF is a file the user
        // points at, so the only question worth asking is whether it is there.
        guard FileManager.default.isReadableFile(atPath: modelPath) else {
            return .unavailable(reason: """
            Aucun fichier GGUF lisible à « \(modelPath) ». \
            Passe --model avec le chemin d'un .gguf.
            """)
        }
        return .ready
    }

    public func chat(
        messages: [ChatMessage],
        tools: [ToolSpec]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let actor = try await LlamaChatActor.shared(
                        modelPath: modelPath, mmprojPath: mmprojPath, tools: tools)
                    for try await event in await actor.chat(messages: messages) {
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension LlamaCppProvider {
    /// Unload every GGUF this process loaded. Call before exiting — see
    /// `LlamaChatActor.releaseAll()` for why leaving it to the runtime aborts.
    public static func releaseLoadedModels() async {
        await LlamaChatActor.releaseAll()
    }
}
