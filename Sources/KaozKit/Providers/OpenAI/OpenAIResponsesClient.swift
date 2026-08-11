import Foundation

/// OpenAI's `/v1/responses`, the surface that accepts function tools and a
/// reasoning effort **together** — `/v1/chat/completions` rejects that pairing
/// for the reasoning families, which is why this client exists alongside
/// `OpenAICompatibleClient` rather than replacing it.
///
/// The wire shape differs from chat completions in three ways that matter:
/// the history is an `input` array mixing role messages with typed items, a
/// tool is declared flat (`{type, name, description, parameters}`) instead of
/// nested under `function`, and the stream carries typed events identified by a
/// `type` field rather than opaque choice deltas.
struct OpenAIResponsesClient {
    let baseURL: URL
    let apiKey: String
    let session: URLSession
    /// `none` / `low` / `medium` / `high` / `xhigh` / `max`, or nil to let the
    /// server pick. Unlike chat completions, any value is legal beside tools.
    let reasoningEffort: String?

    init(
        baseURL: URL, apiKey: String, session: URLSession = .shared,
        reasoningEffort: String? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.reasoningEffort = reasoningEffort
    }

    // MARK: - Chat (streaming)

    func chat(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "/responses"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(
                        "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                        forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 300
                    request.httpBody = try Self.buildBody(
                        model: model, messages: messages, tools: tools,
                        reasoningEffort: reasoningEffort)

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw OpenAICompatibleError.network(message: "réponse non-HTTP")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // The body carries OpenAI's explanation; drain it so the
                        // error says why rather than just "400".
                        var raw = Data()
                        for try await byte in bytes { raw.append(byte) }
                        let body = String(data: raw, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        throw OpenAICompatibleError.http(
                            status: http.statusCode,
                            body: (body?.isEmpty == false) ? body : nil)
                    }

                    var buffer = Data()
                    var metrics = GenerationMetrics()
                    let start = Date()
                    var firstToken: Date?

                    func absorb(_ line: Data) throws {
                        guard let event = try Self.parseLine(line) else { return }
                        switch event {
                        case .text(let delta):
                            if firstToken == nil {
                                firstToken = Date()
                                metrics.timeToFirstToken = firstToken!.timeIntervalSince(start)
                            }
                            continuation.yield(.textDelta(delta))
                        case .reasoning(let delta):
                            if firstToken == nil {
                                firstToken = Date()
                                metrics.timeToFirstToken = firstToken!.timeIntervalSince(start)
                            }
                            continuation.yield(.reasoningDelta(delta))
                        case .toolCall(let id, let name, let arguments):
                            continuation.yield(.toolCall(
                                id: id, name: name, argumentsJSON: arguments))
                        case .usage(let prompt, let completion):
                            metrics.promptTokens = prompt
                            metrics.completionTokens = completion
                        case .failed(let message):
                            throw OpenAICompatibleError.decoding(message: message)
                        }
                    }

                    for try await byte in bytes {
                        if byte == 0x0A {
                            try absorb(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { try absorb(buffer) }

                    if let firstToken {
                        metrics.generationDuration = Date().timeIntervalSince(firstToken)
                    }
                    if metrics != GenerationMetrics() { continuation.yield(.metrics(metrics)) }
                    continuation.finish()
                } catch let urlError as URLError {
                    continuation.finish(
                        throwing: OpenAICompatibleError.network(message: urlError.localizedDescription))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Stream parsing

    /// The subset of `/v1/responses` events this client acts on. Everything
    /// else in the stream (item lifecycle, content-part bookkeeping, output
    /// indices) is progress reporting we don't need.
    enum Event: Equatable {
        case text(String)
        case reasoning(String)
        case toolCall(id: String, name: String, arguments: String)
        case usage(prompt: Int?, completion: Int?)
        case failed(String)
    }

    /// Parses one SSE line. `event:` lines are ignored — every payload repeats
    /// its own `type`, so the `data:` line alone is authoritative.
    static func parseLine(_ raw: Data) throws -> Event? {
        let trimmed = String(decoding: raw, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "response.output_text.delta":
            guard let delta = obj["delta"] as? String, !delta.isEmpty else { return nil }
            return .text(delta)

        // Reasoning is summarised, and only when the request asks for it. Both
        // spellings appear across model families; treat them alike.
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = obj["delta"] as? String, !delta.isEmpty else { return nil }
            return .reasoning(delta)

        // A completed output item. Function calls arrive fully assembled here —
        // the `.delta` events are for progressive display, and StreamEvent
        // documents `.toolCall` as atomic, so we ignore them.
        case "response.output_item.done":
            guard let item = obj["item"] as? [String: Any],
                  item["type"] as? String == "function_call",
                  let callID = item["call_id"] as? String,
                  let name = item["name"] as? String
            else { return nil }
            return .toolCall(
                id: callID, name: name, arguments: (item["arguments"] as? String) ?? "{}")

        case "response.completed", "response.incomplete":
            guard let response = obj["response"] as? [String: Any],
                  let usage = response["usage"] as? [String: Any]
            else { return nil }
            return .usage(
                prompt: usage["input_tokens"] as? Int,
                completion: usage["output_tokens"] as? Int)

        case "response.failed", "error":
            let response = obj["response"] as? [String: Any]
            let error = (response?["error"] as? [String: Any]) ?? (obj["error"] as? [String: Any])
            return .failed((error?["message"] as? String) ?? "la génération a échoué")

        default:
            return nil
        }
    }

    // MARK: - Request

    static func buildBody(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec],
        reasoningEffort: String?
    ) throws -> Data {
        var dict: [String: Any] = [
            "model": model,
            "stream": true,
            "input": inputItems(messages),
        ]
        if let reasoningEffort, !reasoningEffort.isEmpty {
            dict["reasoning"] = ["effort": reasoningEffort]
        }
        if !tools.isEmpty {
            // Flat, unlike chat completions' `{type:"function", function:{…}}`.
            dict["tools"] = try tools.map { spec -> [String: Any] in
                let parameters = try JSONSerialization.jsonObject(
                    with: Data(spec.inputSchemaJSON.utf8))
                return [
                    "type": "function",
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": parameters,
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    /// Flattens our history into the `input` array.
    ///
    /// Role messages and tool items sit side by side at the top level — there
    /// is no assistant-message merging to do, unlike the chat-completions
    /// encoder: a `.toolCall` becomes its own `function_call` item, and a
    /// `.toolResult` its own `function_call_output`, correlated by `call_id`.
    /// An assistant message with empty content is dropped: the API rejects it,
    /// and the tool loop produces exactly that shape when a model calls a tool
    /// without saying anything first.
    static func inputItems(_ messages: [ChatMessage]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for msg in messages {
            switch msg.role {
            case .system, .user:
                out.append(["role": msg.role == .system ? "system" : "user",
                            "content": msg.content])
            case .assistant:
                guard !msg.content.isEmpty else { continue }
                out.append(["role": "assistant", "content": msg.content])
            case .toolCall:
                guard let callID = msg.toolCallID, let name = msg.toolName else { continue }
                out.append([
                    "type": "function_call",
                    "call_id": callID,
                    "name": name,
                    "arguments": msg.content.isEmpty ? "{}" : msg.content,
                ])
            case .toolResult:
                guard let callID = msg.toolCallID else { continue }
                out.append([
                    "type": "function_call_output",
                    "call_id": callID,
                    "output": msg.content,
                ])
            }
        }
        return out
    }
}
