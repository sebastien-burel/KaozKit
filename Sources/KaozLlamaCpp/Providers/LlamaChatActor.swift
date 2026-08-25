import Foundation
import KaozKit
internal import LocalLLMClientCore
internal import LocalLLMClientLlama

/// Owns one loaded GGUF model and turns KaozKit chat turns into llama.cpp
/// generations.
///
/// Cached per (model, tool set) because `LlamaClient` bakes the tool schemas into
/// its chat params at construction: changing the tools means a new client, and a
/// new client means reloading the model. That is affordable only because a run's
/// tool set is fixed — `TyKaozHost.chat` passes the same registry every round.
actor LlamaChatActor {
    private let client: LlamaClient

    private init(client: LlamaClient) {
        self.client = client
    }

    // MARK: - Cache

    /// Identifies a loaded client: same model, same tools ⇒ same actor.
    private struct Key: Hashable {
        let modelPath: String
        let mmprojPath: String?
        let toolSignature: String
    }

    private static let cache = Cache()

    private actor Cache {
        var actors: [Key: LlamaChatActor] = [:]

        func actor(for key: Key, make: () async throws -> LlamaChatActor) async throws -> LlamaChatActor {
            if let existing = actors[key] { return existing }
            let made = try await make()
            actors[key] = made
            return made
        }

        func releaseAll() {
            actors.removeAll()
        }
    }

    /// Drop every loaded model, freeing its llama.cpp context and Metal buffers.
    ///
    /// Must happen before the process exits. Swift does not deinitialise globals
    /// at exit, but C++ *does* run its static destructors: ggml then frees the
    /// Metal device while our contexts still hold buffers on it, and asserts
    /// (`[rsets->data count] == 0`). Releasing here puts the teardown back in
    /// order.
    static func releaseAll() async {
        await cache.releaseAll()
    }

    static func shared(
        modelPath: String, mmprojPath: String?, tools: [ToolSpec]
    ) async throws -> LlamaChatActor {
        let key = Key(
            modelPath: modelPath, mmprojPath: mmprojPath,
            toolSignature: signature(of: tools))
        return try await cache.actor(for: key) {
            let client = try await LocalLLMClient.llama(
                url: URL(fileURLWithPath: modelPath),
                mmprojURL: mmprojPath.map { URL(fileURLWithPath: $0) },
                erasedTools: tools.map(erase))
            return LlamaChatActor(client: client)
        }
    }

    /// Name + schema, so a tool whose schema changed does not silently reuse a
    /// client that advertised the old one.
    private static func signature(of tools: [ToolSpec]) -> String {
        tools
            .map { "\($0.name)\u{1}\($0.inputSchemaJSON)" }
            .sorted()
            .joined(separator: "\u{2}")
    }

    // MARK: - Generation

    func chat(messages: [ChatMessage]) -> AsyncThrowingStream<StreamEvent, Error> {
        let input = LLMInput.chat(messages.map(Self.convert))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in try await client.responseStream(from: input) {
                        if Task.isCancelled { break }
                        switch chunk {
                        case .text(let text):
                            continuation.yield(.textDelta(text))
                        case .toolCall(let call):
                            // LLMToolCall already carries an id (a UUID when the
                            // model gave none), so unlike the MLX path there is
                            // nothing to synthesise here.
                            continuation.yield(.toolCall(
                                id: call.id, name: call.name,
                                argumentsJSON: call.arguments))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Conversions

    private static func convert(_ message: ChatMessage) -> LLMInput.Message {
        switch message.role {
        case .system:
            return .init(role: .system, content: message.content)
        case .user:
            return .init(role: .user, content: message.content)
        case .assistant:
            return .init(role: .assistant, content: message.content)
        case .toolCall:
            // The assistant's own tool-call turn. The transformer has no
            // structured `tool_calls` field to fill, so it rides in as the
            // assistant text it will be rendered as anyway.
            return .init(role: .assistant, content: message.content)
        case .toolResult:
            var converted = LLMInput.Message(role: .tool, content: message.content)
            if let id = message.toolCallID {
                converted.metadata["tool_call_id"] = id
            }
            return converted
        }
    }
}

/// A `ToolSpec` as a tool llama.cpp can be told about.
///
/// The schema is the whole point: it is JSON from a registry, discovered while
/// running, which is why this goes through `AnyLLMTool`'s runtime initializer.
/// The call closure is never invoked — KaozKit runs its own tool loop in
/// `TyKaozHost.chat` and only needs the model to *emit* the call.
private func erase(_ spec: ToolSpec) -> AnyLLMTool {
    AnyLLMTool(
        name: spec.name,
        description: spec.description,
        argumentsSchema: schemaDictionary(spec.inputSchemaJSON),
        call: { _ in
            throw LlamaToolError.notExecutedHere(name: spec.name)
        })
}

enum LlamaToolError: LocalizedError {
    case notExecutedHere(name: String)

    var errorDescription: String? {
        switch self {
        case .notExecutedHere(let name):
            return "l'outil « \(name) » s'exécute côté KaozKit, pas dans le client llama"
        }
    }
}

/// Parse a JSON Schema string into the `Sendable` dictionary the client wants.
///
/// `JSONSerialization` hands back `NSString`/`NSNumber`/`NSNull`, none of which
/// are `Sendable`, so the tree is rebuilt with Swift-native values on the way
/// through rather than force-cast.
private func schemaDictionary(_ json: String) -> [String: any Sendable] {
    guard
        let data = json.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data),
        let object = sendableJSON(parsed) as? [String: any Sendable]
    else { return [:] }
    return object
}

private func sendableJSON(_ value: Any) -> (any Sendable)? {
    switch value {
    case let dict as [String: Any]:
        return dict.reduce(into: [String: any Sendable]()) { out, pair in
            if let converted = sendableJSON(pair.value) { out[pair.key] = converted }
        }
    case let array as [Any]:
        return array.compactMap(sendableJSON)
    case let string as String:
        return string
    case let number as NSNumber:
        // CFBoolean answers to the same class, so ask it apart from the numbers.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if number.stringValue.contains(".") { return number.doubleValue }
        return number.intValue
    case is NSNull:
        return nil
    default:
        return nil
    }
}
