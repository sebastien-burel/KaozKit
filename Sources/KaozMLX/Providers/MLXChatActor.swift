import Foundation
import KaozKit
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// One owner of the loaded chat `ModelContainer` per modelID. Like
/// `MLXEmbeddingActor`, isolates Metal-bound work so overlapping
/// `chat()` calls don't interleave on the single command queue.
///
/// Lazy load on first `chat()`. Idle-unload (Phase C3) is wired in
/// a follow-up commit — for now the container lives until the
/// actor itself is dropped.
public actor MLXChatActor {
    private static var instances: [String: MLXChatActor] = [:]

    @MainActor
    static public func shared(for modelID: String) -> MLXChatActor {
        if let existing = instances[modelID] { return existing }
        let actor = MLXChatActor(modelID: modelID)
        instances[modelID] = actor
        return actor
    }

    /// How hard the model should think, when its chat template exposes the
    /// knob. `.auto` sends nothing and keeps the template's own default.
    public enum ReasoningEffort: String, Sendable {
        case auto, low, medium, high

        public init(setting: String) {
            self = ReasoningEffort(rawValue: setting) ?? .auto
        }
    }

    public let modelID: String
    private var container: ModelContainer?

    /// Whether the loaded model's chat template reads `reasoning_effort`,
    /// and whether it spells the top level `xhigh`. Read once at load:
    /// the vocabulary differs by family, and Qwen 3.5 raises a Jinja
    /// exception on a value it doesn't know, so a hardcoded level would
    /// break generation outright.
    private var templateReadsReasoningEffort = false
    private var templateUsesXHigh = false
    private let downloader: any Downloader
    private let tokenizerLoader: any TokenizerLoader

    /// Snapshot of when the last chat() call completed. The
    /// idle-unload task compares against this to decide whether
    /// activity has happened since it was scheduled.
    private var lastUsedAt: Date = .distantPast
    private var idleUnloadTask: Task<Void, Never>?

    /// Default idle threshold before unloading the container. 5
    /// minutes — short enough to feel polite on a 16 GB Mac running
    /// the wiki embedder + a chat model, long enough to absorb a
    /// "I'll come back in a minute" pause without forcing a reload.
    private let idleTimeout: TimeInterval = 5 * 60

    private init(modelID: String) {
        self.modelID = modelID
        self.downloader = #hubDownloader()
        self.tokenizerLoader = #huggingFaceTokenizerLoader()
    }

    // MARK: - Public

    /// Streams one chat round. The returned stream yields
    /// `StreamEvent`s mapped from mlx-swift-lm's `Generation`
    /// stream — `.chunk(text)` → `.textDelta`, `.toolCall` →
    /// `.toolCall` with a UUID id (MLX's ToolCall has no id field;
    /// we synthesise one so our agent loop can route results back).
    public func chat(
        messages: [ChatMessage],
        tools: [KaozKit.ToolSpec],
        reasoningEffort: ReasoningEffort = .auto
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Cancel any pending unload — fresh activity.
                idleUnloadTask?.cancel()
                idleUnloadTask = nil

                do {
                    // Say so before the wait, not after: loading a local
                    // model is the longest silence of the turn, and it comes
                    // back mid-conversation once the idle unload has fired.
                    if self.container == nil { continuation.yield(.loadingModel) }
                    let container = try await loadIfNeeded()
                    // Time to first token, started here: the weight load
                    // above is the first turn's one-off cost, not a property
                    // of the generation, but everything below it counts —
                    // `container.generate` builds the token iterator, and
                    // that is where the prompt is prefilled. Timing from
                    // after that call reported a TTFT shorter than the
                    // prefill window it is supposed to contain.
                    let generationStart = ContinuousClock.now
                    // gpt-oss speaks OpenAI's Harmony format: its chat
                    // template needs assistant tool calls in a structured
                    // `tool_calls` field (free text raises a Jinja
                    // exception), and mlx-swift-lm has no Harmony parser,
                    // so we both build the prompt and parse the output
                    // ourselves.
                    let isHarmony = modelID.localizedCaseInsensitiveContains("gpt-oss")
                        || modelID.localizedCaseInsensitiveContains("gpt_oss")
                        || modelID.localizedCaseInsensitiveContains("gptoss")
                    let mappedTools = tools.isEmpty ? nil : tools.compactMap(Self.mapTool)
                    let context = reasoningEffortContext(reasoningEffort)
                    let userInput = isHarmony
                        ? UserInput(
                            messages: Self.mapMessagesHarmony(messages),
                            tools: mappedTools,
                            additionalContext: context)
                        : UserInput(
                            chat: Self.mapMessages(messages),
                            tools: mappedTools,
                            additionalContext: context)
                    let lmInput = try await container.prepare(input: userInput)
                    let params = GenerateParameters(
                        maxTokens: 4096,
                        temperature: 0.7
                    )
                    let stream = try await container.generate(
                        input: lmInput,
                        parameters: params
                    )
                    // Stateful intercept layer for Gemma 4. MLX's
                    // GemmaFunctionParser targets the Gemma 3
                    // tokens (`<start_function_call>`,
                    // `<end_function_call>`, `<escape>`); Gemma 4
                    // ships different ones (`<|tool_call>`,
                    // `<tool_call|>`, `<|"|>`). Until mlx-swift-lm
                    // catches up we splice in a tiny parser.
                    // Pick the streaming marker set for this model:
                    // Gemma 4 needs its tool-call + channel envelopes
                    // spliced out; everything else (Qwen 3, DeepSeek-R1…)
                    // emits `<think>` reasoning tags. Either way the
                    // buffered parser strips them from the answer.
                    let needsGemma4 = modelID.localizedCaseInsensitiveContains("gemma-4")
                        || modelID.localizedCaseInsensitiveContains("gemma4")
                    let blocks = needsGemma4 ? Self.gemma4Blocks : Self.thinkBlocks
                    var streamState = StreamState()
                    // Qwen 3.5 (and the DeepSeek-R1 distills) end the
                    // generation prompt with the `<think>` marker, so the
                    // model only ever emits the closing tag. Start the
                    // parser inside the reasoning block, or the whole chain
                    // of thought lands in the answer with a stray
                    // `</think>` at the end of it.
                    if !isHarmony, !needsGemma4,
                       let think = blocks.first,
                       await Self.promptOpensReasoning(lmInput, container: container) {
                        streamState.block = think
                    }
                    var harmony = HarmonyParser()
                    var firstChunkAt: ContinuousClock.Instant?

                    for await event in stream {
                        if Task.isCancelled { break }
                        switch event {
                        case .chunk(let text):
                            if firstChunkAt == nil { firstChunkAt = .now }
                            if isHarmony {
                                harmony.consume(text, into: continuation)
                            } else {
                                Self.processStreamChunk(
                                    text,
                                    blocks: blocks,
                                    state: &streamState,
                                    continuation: continuation
                                )
                            }
                        case .toolCall(let call):
                            // MLX `ToolCall` has no id; synthesise
                            // one so TyKaoz's ChatSession can route
                            // results back deterministically.
                            let argsJSON: String
                            if let data = try? JSONEncoder().encode(call.function.arguments),
                               let str = String(data: data, encoding: .utf8) {
                                argsJSON = str
                            } else {
                                argsJSON = "{}"
                            }
                            continuation.yield(.toolCall(
                                id: "mlx-" + UUID().uuidString.prefix(8).lowercased(),
                                name: call.function.name,
                                argumentsJSON: argsJSON
                            ))
                        case .info(let info):
                            continuation.yield(.metrics(Self.metrics(
                                from: info,
                                timeToFirstToken: firstChunkAt.map {
                                    Self.seconds(generationStart.duration(to: $0))
                                }
                            )))
                        }
                    }
                    if isHarmony {
                        harmony.finish(into: continuation)
                    } else {
                        Self.flushStreamState(&streamState, continuation: continuation)
                    }
                    lastUsedAt = Date()
                    scheduleIdleUnload()
                    continuation.finish()
                } catch {
                    // Even on failure, kick off the idle countdown
                    // so a stuck container doesn't hold memory if
                    // the user gives up after one bad round.
                    lastUsedAt = Date()
                    scheduleIdleUnload()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drops the loaded container. Releases GPU buffers + ~few GB
    /// RAM for 4-bit chat models. Called by the idle-unload timer
    /// and exposed publicly so the Phase B settings UI could wire
    /// a manual "décharger" button later if anyone asks.
    public func unload() {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil
        container = nil
    }

    /// Unloads every loaded chat container — the manual "décharger"
    /// command. Each container drop releases its GPU buffers; call
    /// `MLX.GPU.clearCache()` afterwards to return the freed memory
    /// to the system rather than keeping it in MLX's buffer cache.
    @MainActor
    static public func unloadAll() async {
        for actor in instances.values { await actor.unload() }
    }

    /// MLX's end-of-generation report, mapped onto the shared metrics
    /// shape. It measures both phases itself — prefill and decode — so only
    /// the latency to the first token is ours to time; nil when the round
    /// emitted no chunk at all, a tool call straight out of the prompt.
    public static func metrics(
        from info: GenerateCompletionInfo,
        timeToFirstToken: TimeInterval?
    ) -> GenerationMetrics {
        var metrics = GenerationMetrics()
        metrics.promptTokens = info.promptTokenCount
        metrics.completionTokens = info.generationTokenCount
        metrics.promptDuration = info.promptTime
        metrics.generationDuration = info.generateTime
        metrics.timeToFirstToken = timeToFirstToken
        return metrics
    }

    /// `Duration` as plain seconds, for the metrics fields.
    private static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }

    // MARK: - Memory probe

    /// Real-conditions memory footprint of a loaded model, in bytes of
    /// Metal/unified memory. `resident` is the active allocation right
    /// after load (≈ the quantised weights, the dominant term for the
    /// RAM floor); `peak` is the high-water mark across the probe
    /// generation (weights + KV cache + activations).
    public struct MemoryReport: Sendable {
        public let residentBytes: Int
        public let peakBytes: Int
    }

    /// Loads the model (downloading first if needed) and runs a short
    /// canned generation, measuring what MLX actually allocates. This
    /// is the truthful way to size `min/recommended_ram_gb` instead of
    /// estimating from the on-disk weight size.
    ///
    /// Caveat: the probe prompt is **text-only**. For a VLM the vision
    /// tower isn't exercised, so attaching an image at chat time pushes
    /// the real peak higher than what this reports.
    public func measureMemory() async throws -> MemoryReport {
        idleUnloadTask?.cancel()
        idleUnloadTask = nil

        MLX.GPU.resetPeakMemory()
        let container = try await loadIfNeeded()
        let resident = MLX.Memory.activeMemory

        let input = UserInput(chat: [.user("Introduce yourself in one sentence.")])
        let lmInput = try await container.prepare(input: input)
        let params = GenerateParameters(maxTokens: 64, temperature: 0.7)
        let stream = try await container.generate(input: lmInput, parameters: params)
        for await _ in stream {
            if Task.isCancelled { break }
        }
        let peak = MLX.Memory.peakMemory

        lastUsedAt = Date()
        scheduleIdleUnload()
        return MemoryReport(residentBytes: resident, peakBytes: peak)
    }

    // MARK: - Idle unload

    /// Starts (or restarts) the idle-unload countdown. The task
    /// snapshots `lastUsedAt` at scheduling time; on wake it
    /// compares against the current value — if anything has used
    /// the actor in the meantime, the snapshot has moved and the
    /// unload is skipped. This way two overlapping schedulings
    /// don't double-unload.
    private func scheduleIdleUnload() {
        idleUnloadTask?.cancel()
        let scheduledAt = lastUsedAt
        let timeoutNanos = UInt64(idleTimeout * 1_000_000_000)
        idleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanos)
            if Task.isCancelled { return }
            await self?.unloadIfStill(scheduledAt: scheduledAt)
        }
    }

    private func unloadIfStill(scheduledAt: Date) {
        guard lastUsedAt == scheduledAt else { return }
        container = nil
        idleUnloadTask = nil
    }

    // MARK: - Internals

    private func loadIfNeeded() async throws -> ModelContainer {
        if let container { return container }
        _ = try await MLXModelStore.shared.download(modelID: modelID)

        // A chat model with no chat template would make swift-transformers
        // fall back to raw-text formatting and then hard-crash
        // (`fatalError` on an unmapped token) during encoding — not
        // catchable. Refuse with a clear message instead of taking the
        // whole app down. We check the same places the loader does.
        let localDir = await MLXModelStore.shared.localDirectory(modelID: modelID)
        if let localDir, !Self.hasChatTemplate(in: localDir) {
            throw ChatError.missingChatTemplate(modelID: modelID)
        }
        let template = localDir.flatMap(Self.chatTemplateText(in:)) ?? ""
        templateReadsReasoningEffort = template.contains("reasoning_effort")
        templateUsesXHigh = template.contains("xhigh")

        // Route on the catalog flag: VLM entries go through
        // VLMModelFactory (which knows about vision towers +
        // image processors), text-only chat through LLMModelFactory.
        // Off-catalog IDs — the ones a user adds by hand — fall back to
        // what the downloaded config declares, rather than assuming text:
        // a supported VLM added that way would otherwise reach the wrong
        // factory and fail as if it were unsupported. The catalog stays
        // authoritative when it has an opinion.
        let entry = await ModelCatalogService.shared.entry(forID: modelID)
        let isVision = entry?.isVision
            ?? localDir.map(Self.declaresVisionTower(in:))
            ?? false
        let config = ModelConfiguration(id: modelID, revision: entry?.revision ?? "main")
        let loaded: ModelContainer
        do {
            if isVision {
                loaded = try await VLMModelFactory.shared.loadContainer(
                    from: downloader,
                    using: tokenizerLoader,
                    configuration: config
                ) { _ in }
            } else {
                loaded = try await LLMModelFactory.shared.loadContainer(
                    from: downloader,
                    using: tokenizerLoader,
                    configuration: config
                ) { _ in }
            }
        } catch let error as ModelFactoryError {
            // "Unsupported model type: x" reads like the model is broken.
            // It means mlx-swift-lm has no implementation for that
            // architecture — say so, and leave every other factory error
            // (unreadable or malformed config) untouched.
            switch error {
            case .unsupportedModelType(let type), .unsupportedProcessorType(let type):
                throw ChatError.architectureNotImplemented(modelID: modelID, type: type)
            default:
                throw error
            }
        }
        // mlx-swift-lm's `infer(from: model_type)` only recognises
        // exact "gemma" — Gemma 3/4 ship config.json with model_type
        // "gemma4" (or "gemma3", "gemma3_text", …), so the tool-call
        // format silently falls back to `.json`. Result: the model
        // emits its native `call:name{key:value}` envelope as raw
        // text and we relay it as `.textDelta`. Fix it explicitly
        // for the Gemma family.
        if modelID.localizedCaseInsensitiveContains("gemma") {
            await loaded.update { ctx in
                ctx.configuration.toolCallFormat = .gemma
            }
        }

        container = loaded
        await MLXModelStore.shared.touch(modelID: modelID)
        return loaded
    }

    public enum ChatError: LocalizedError {
        case missingChatTemplate(modelID: String)
        case architectureNotImplemented(modelID: String, type: String)

        public var errorDescription: String? {
            switch self {
            case .architectureNotImplemented(let modelID, let type):
                // Ne pas affirmer que l'amont ignore cette architecture : depuis
                // le binaire, on ne sait que ce que connaît la version compilée
                // ici. `gemma4_unified` existait en amont alors que la version
                // épinglée l'ignorait — dire « pas implémenté » envoyait chercher
                // un autre runtime quand il suffisait de changer de version.
                return """
                "\(modelID)" uses the "\(type)" architecture, which the \
                version of mlx-swift-lm compiled here does not implement — \
                the model is not at fault, and re-downloading will not \
                change anything. A newer mlx-swift-lm may know it; \
                otherwise, use this model through a runtime that supports \
                it (Ollama, LM Studio).
                """
            case .missingChatTemplate(let modelID):
                return """
                "\(modelID)" ships no chat template (neither \
                `chat_template` in `tokenizer_config.json` nor a \
                `chat_template.jinja` file). This model is not usable \
                as-is — re-quantize the repo with the template included.
                """
            }
        }
    }

    /// True when the model directory carries a chat template in one of
    /// the places the loader looks: a standalone `chat_template.jinja`
    /// (Gemma ships it this way) or a `chat_template` field inside
    /// `tokenizer_config.json`. Without either, message formatting falls
    /// back to raw text and the tokenizer fatal-errors on encode.
    private static func hasChatTemplate(in dir: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.appendingPathComponent("chat_template.jinja").path) {
            return true
        }
        let tcURL = dir.appendingPathComponent("tokenizer_config.json")
        guard let data = try? Data(contentsOf: tcURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["chat_template"] != nil
    }

    /// The model's chat template as text, from whichever of the two places
    /// carries it. Used to find out which knobs the template actually reads.
    private static func chatTemplateText(in dir: URL) -> String? {
        let jinja = dir.appendingPathComponent("chat_template.jinja")
        if let text = try? String(contentsOf: jinja, encoding: .utf8) {
            return text
        }
        let tcURL = dir.appendingPathComponent("tokenizer_config.json")
        guard let data = try? Data(contentsOf: tcURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj["chat_template"] as? String
    }

    /// The Jinja context carrying the chosen reasoning effort, or `nil` when
    /// there is nothing to say. Sent only to templates that read the key —
    /// Qwen 3.5 accepts `low | medium | xhigh` and raises on anything else,
    /// gpt-oss wants `low | medium | high`, so the top level is spelled the
    /// way this model's template spells it.
    private func reasoningEffortContext(
        _ effort: ReasoningEffort
    ) -> [String: any Sendable]? {
        guard effort != .auto, templateReadsReasoningEffort else { return nil }
        let value = (effort == .high && templateUsesXHigh) ? "xhigh" : effort.rawValue
        return ["reasoning_effort": value]
    }

    /// True when the downloaded `config.json` declares a vision tower.
    /// Every multimodal type mlx-swift-lm registers carries a
    /// `vision_config` block, so its presence is a reliable signal for a
    /// model the catalog says nothing about. Absent or unreadable config
    /// ⇒ false, i.e. the previous text-only assumption.
    private static func declaresVisionTower(in dir: URL) -> Bool {
        let url = dir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return obj["vision_config"] != nil
    }

    // MARK: - Mapping

    /// Converts TyKaoz's ChatMessage history into MLX's Chat.Message.
    /// Tool calls round-trip best-effort: MLX's Chat.Message has no
    /// dedicated tool-call slot on the assistant role, so we serialise
    /// the call as JSON inside an assistant message. The model's chat
    /// template re-parses this. Tool results map cleanly to `.tool(...)`.
    private static func mapMessages(_ messages: [ChatMessage]) -> [Chat.Message] {
        // Gemma 4 in mlx-swift-lm only supports a SINGLE image per prompt:
        // its token check compares total image placeholders to the
        // per-image soft-token count, so two images (e.g. one per turn,
        // accumulated in history) throw a mismatch. Keep only the most
        // recent image across the whole prompt, capped to one.
        let imageIndex = messages.lastIndex { !$0.imageURLs.isEmpty }
        return messages.enumerated().compactMap { index, msg in
            switch msg.role {
            case .system:
                return .system(msg.content)
            case .user:
                // Attach the single kept image (VLM): UserInput loads it
                // from its file URL. Non-VLM models never get images here.
                let images = (index == imageIndex)
                    ? msg.imageURLs.prefix(1).map { UserInput.Image.url($0) }
                    : []
                return .user(msg.content, images: images)
            case .assistant:
                return .assistant(msg.content)
            case .toolCall:
                let name = msg.toolName ?? "unknown"
                let body = msg.content.isEmpty ? "{}" : msg.content
                return .assistant("<tool_call>{\"name\":\"\(name)\",\"arguments\":\(body)}</tool_call>")
            case .toolResult:
                return .tool(msg.content)
            }
        }
    }

    /// Builds raw Harmony message dicts for gpt-oss. The gpt-oss chat
    /// template (unlike `Chat.Message`, which is role + content only)
    /// requires assistant tool calls in a structured `tool_calls`
    /// field and tool results in a `tool` role message — anything else
    /// raises a Jinja `TemplateException`. We feed the template these
    /// dicts directly through `UserInput(messages:)`.
    private static func mapMessagesHarmony(_ messages: [ChatMessage]) -> [[String: any Sendable]] {
        messages.map { msg in
            switch msg.role {
            case .system:
                return ["role": "system", "content": msg.content]
            case .user:
                return ["role": "user", "content": msg.content]
            case .assistant:
                return ["role": "assistant", "content": msg.content]
            case .toolCall:
                return [
                    "role": "assistant",
                    "tool_calls": [[
                        "type": "function",
                        "function": [
                            "name": msg.toolName ?? "unknown",
                            "arguments": sendableJSONObject(msg.content),
                        ] as [String: any Sendable],
                    ] as [String: any Sendable]],
                ]
            case .toolResult:
                return ["role": "tool", "content": msg.content]
            }
        }
    }

    /// Parses a JSON-object string into native Swift `Sendable` values
    /// for the Jinja rendering context. The template re-serialises this
    /// with `|tojson`, so types must survive the round-trip; returns an
    /// empty object when parsing fails.
    private static func sendableJSONObject(_ json: String) -> [String: any Sendable] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return [:] }
        return dict.compactMapValues(sendableJSONValue)
    }

    private static func sendableJSONValue(_ value: Any) -> (any Sendable)? {
        switch value {
        case let s as String:
            return s
        case let n as NSNumber:
            // NSNumber conflates Bool/Int/Double — disambiguate so the
            // template re-serialises the right JSON type. (`true as? Int`
            // succeeds, so the Bool check must come first.)
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            if CFNumberIsFloatType(n) { return n.doubleValue }
            return n.intValue
        case let arr as [Any]:
            return arr.compactMap(sendableJSONValue)
        case let dict as [String: Any]:
            return dict.compactMapValues(sendableJSONValue)
        default:
            return nil
        }
    }

    /// Streaming-aware Gemma 4 tool-call detector. MLX's built-in
    /// `GemmaFunctionParser` targets Gemma 3's tokens; this routine
    /// catches the Gemma 4 envelope (`<|tool_call>call:NAME{ARGS}
    /// <tool_call|>` with `<|"|>STR<|"|>` for strings) and emits
    /// `.toolCall` events alongside the surrounding text.
    ///
    /// Invariants:
    /// - When `inCall == false`, `buffer` holds only the tail of
    ///   the stream that might still be a partial open marker.
    ///   Everything safely past it is already emitted as `.textDelta`.
    /// - When `inCall == true`, `buffer` holds the entire span from
    ///   the open marker forward, waiting for the close marker so
    ///   the payload can be parsed atomically.
    /// How the content between a pair of markers should be routed:
    /// `.toolCall` runs through `parseGemma4Payload`; `.reasoning`
    /// goes out as `.reasoningDelta` (kept for round-trip, not
    /// rendered in the chat view); `.suppress` is dropped.
    private enum StreamBlockKind {
        case toolCall
        case reasoning
        case suppress
    }
    /// A marker-delimited span the streaming parser recognises: any of
    /// `opens` starts it, any of `closes` ends it, `kind` says where it
    /// goes. Multiple closes let one envelope accept several wire formats.
    private struct StreamBlock {
        let opens: [String]
        let closes: [String]
        let kind: StreamBlockKind
    }
    /// Inline tokens Gemma 4 emits that its chat template fails to
    /// suppress — tool-call envelopes and internal-monologue channels.
    private static let gemma4Blocks: [StreamBlock] = [
        // Tool-call envelopes. Gemma 4 emits two shapes depending on the
        // model: its native `call:NAME{…}` closed by `<tool_call|>`, and
        // (notably the 26B) the Hermes-style `{"name":…}` closed by
        // `</tool_call>`. Accept both close forms.
        StreamBlock(
            opens: ["<|tool_call>", "<tool_call>"],
            closes: ["<tool_call|>", "</tool_call>"],
            kind: .toolCall
        ),
        // Tool-response envelopes. After a real tool round, the chat
        // template wraps the result in `<|tool_response>…<tool_response|>`
        // in the prompt; Gemma 4 then echoes that envelope back at the
        // start of its final answer. Drop it — TyKaoz already renders the
        // genuine result from its own `.toolResult` message. Accept both
        // the native (`<tool_response|>`) and Hermes (`</tool_response>`)
        // close forms, mirroring the tool-call block.
        StreamBlock(
            opens: ["<|tool_response>", "<tool_response>"],
            closes: ["<tool_response|>", "</tool_response>"],
            kind: .suppress
        ),
        // Inline channel marker — Gemma 4 uses these to label
        // internal monologue. Surface as reasoning so the next
        // round can carry it back if needed; the chat view drops
        // `.reasoningDelta` events from display.
        StreamBlock(
            opens: ["<|channel>"],
            closes: ["<channel|>"],
            kind: .reasoning
        ),
    ]
    /// Reasoning tags used by Qwen 3, DeepSeek-R1, QwQ and friends.
    /// The `<think>…</think>` span is the model's chain of thought —
    /// route it to reasoning so it doesn't leak into the answer.
    private static let thinkBlocks: [StreamBlock] = [
        StreamBlock(opens: ["<think>"], closes: ["</think>"], kind: .reasoning),
    ]

    /// True when the rendered prompt already opened a `<think>` block that
    /// it never closed — the model will emit only the closing tag. Read off
    /// the tokenised prompt rather than guessed from the model id: it is
    /// what the model is actually conditioned on, and it covers every
    /// family that prefills the marker (Qwen 3.5, DeepSeek-R1, GLM) without
    /// a list to keep up to date. Sixteen tokens cover both
    /// `<|im_start|>assistant\n<think>\n` and the thinking-disabled form
    /// `<think>\n\n</think>\n\n`, which must read as *not* open.
    private static func promptOpensReasoning(
        _ input: LMInput,
        container: ModelContainer
    ) async -> Bool {
        let tokens = input.text.tokens.reshaped(-1).asArray(Int.self)
        guard !tokens.isEmpty else { return false }
        let tail = Array(tokens.suffix(16))
        let text = await container.perform { ctx in
            ctx.tokenizer.decode(tokenIds: tail)
        }
        guard let open = text.range(of: "<think>", options: .backwards) else { return false }
        if let close = text.range(of: "</think>", options: .backwards),
           close.lowerBound > open.lowerBound {
            return false
        }
        return true
    }

    /// Streaming parser state: the pending buffer plus the block we are
    /// currently inside, if any. Explicit rather than inferred from the
    /// buffer's prefix, because the block can be *pre-opened*: Qwen 3.5
    /// (and the DeepSeek-R1 distills) put the `<think>` marker in the
    /// generation prompt itself, so the model only ever emits the closing
    /// tag. It also lets a reasoning block flush out as it streams instead
    /// of being held whole until its close marker arrives.
    private struct StreamState {
        var buffer = ""
        var block: StreamBlock?
        /// The marker that opened `block`, replayed in the raw span when a
        /// tool call fails to parse. Empty when the block was pre-opened.
        var openMarker = ""
        /// True once the active reasoning block emitted a delta — only the
        /// first slice gets its leading whitespace trimmed.
        var reasoningStarted = false
    }

    /// Streaming-aware marker stripper. `blocks` is the marker set for the
    /// current model (Gemma 4 envelopes, or generic `<think>` tags).
    private static func processStreamChunk(
        _ text: String,
        blocks: [StreamBlock],
        state: inout StreamState,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        let allOpens = blocks.flatMap(\.opens)
        let maxOpenLen = allOpens.map(\.count).max() ?? 0
        state.buffer += text

        // Process the buffer repeatedly until no transition is
        // possible (handles edge cases like multiple tool calls or
        // a tool call sandwiched between text in one chunk).
        while true {
            if let block = state.block {
                // Inside a block — look for the earliest of its close
                // markers (an envelope may accept several wire formats).
                var closeRange: Range<String.Index>? = nil
                for close in block.closes {
                    if let range = state.buffer.range(of: close),
                       closeRange == nil || range.lowerBound < closeRange!.lowerBound {
                        closeRange = range
                    }
                }
                guard let closeRange else {
                    // No close yet. Reasoning goes out as it comes so the
                    // "Réflexion" panel fills while the model thinks —
                    // holding it back would leave an empty bubble for as
                    // long as the chain of thought runs. Tool calls and
                    // suppressed envelopes must stay atomic, so they wait.
                    if block.kind == .reasoning {
                        let maxCloseLen = block.closes.map(\.count).max() ?? 0
                        if state.buffer.count > maxCloseLen {
                            let safeEnd = state.buffer.index(
                                state.buffer.endIndex, offsetBy: -maxCloseLen)
                            emitReasoning(
                                String(state.buffer[..<safeEnd]),
                                closing: false,
                                state: &state,
                                continuation: continuation
                            )
                            state.buffer = String(state.buffer[safeEnd...])
                        }
                    }
                    return
                }
                let payload = String(state.buffer[..<closeRange.lowerBound])
                let raw = state.openMarker + String(state.buffer[..<closeRange.upperBound])
                emitStreamBlock(
                    block.kind,
                    payload: payload,
                    raw: raw,
                    state: &state,
                    continuation: continuation
                )
                state.buffer = String(state.buffer[closeRange.upperBound...])
                state.block = nil
                state.openMarker = ""
                state.reasoningStarted = false
            } else {
                // Outside any block — scan for the earliest open
                // marker of any kind.
                var earliest: (range: Range<String.Index>, block: StreamBlock, marker: String)? = nil
                for block in blocks {
                    for open in block.opens {
                        if let range = state.buffer.range(of: open) {
                            if earliest == nil || range.lowerBound < earliest!.range.lowerBound {
                                earliest = (range, block, open)
                            }
                        }
                    }
                }
                if let found = earliest {
                    let prefix = String(state.buffer[..<found.range.lowerBound])
                    if !prefix.isEmpty {
                        continuation.yield(.textDelta(prefix))
                    }
                    state.buffer = String(state.buffer[found.range.upperBound...])
                    state.block = found.block
                    state.openMarker = found.marker
                    state.reasoningStarted = false
                } else {
                    // No open marker. Emit everything except a tail
                    // big enough to hide a split-across-chunks marker.
                    if state.buffer.count > maxOpenLen {
                        let safeEnd = state.buffer.index(
                            state.buffer.endIndex, offsetBy: -maxOpenLen)
                        let safe = String(state.buffer[..<safeEnd])
                        if !safe.isEmpty {
                            continuation.yield(.textDelta(safe))
                        }
                        state.buffer = String(state.buffer[safeEnd...])
                    }
                    return
                }
            }
        }
    }

    /// Flushes what's left when the stream ends: a leftover half-marker
    /// that turned out to be literal text, trailing content, or — when
    /// generation was cut off mid-block — the unterminated block itself.
    /// Routing by the active block matters: a truncated chain of thought
    /// must stay reasoning instead of landing in the answer.
    private static func flushStreamState(
        _ state: inout StreamState,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        guard !state.buffer.isEmpty else { return }
        let rest = state.buffer
        state.buffer = ""
        guard let block = state.block else {
            continuation.yield(.textDelta(rest))
            return
        }
        emitStreamBlock(
            block.kind,
            payload: rest,
            raw: state.openMarker + rest,
            state: &state,
            continuation: continuation
        )
    }

    /// Routes a closed block to the right `StreamEvent`.
    private static func emitStreamBlock(
        _ kind: StreamBlockKind,
        payload: String,
        raw: String,
        state: inout StreamState,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        switch kind {
        case .toolCall:
            if let parsed = parseGemma4Payload(payload) {
                continuation.yield(.toolCall(
                    id: "mlx-" + UUID().uuidString.prefix(8).lowercased(),
                    name: parsed.name,
                    argumentsJSON: parsed.argumentsJSON
                ))
            } else {
                // Couldn't parse — emit the raw span as text so
                // nothing is silently swallowed.
                continuation.yield(.textDelta(raw))
            }
        case .reasoning:
            // Discard the channel name, keep the content. The chat view
            // shows it in a collapsible panel and the next round can
            // carry it through if the provider supports it.
            emitReasoning(payload, closing: true, state: &state, continuation: continuation)
        case .suppress:
            // Eat the whole block silently.
            break
        }
    }

    /// Emits one slice of a `.reasoning` block. Whitespace is trimmed only
    /// at the block's edges — the leading whitespace of the first slice,
    /// the trailing whitespace of the closing one. Trimming every slice
    /// would eat the spacing inside the chain of thought.
    private static func emitReasoning(
        _ slice: String,
        closing: Bool,
        state: inout StreamState,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) {
        var out = slice
        if !state.reasoningStarted {
            out = String(out.drop(while: \.isWhitespace))
        }
        if closing {
            while let last = out.last, last.isWhitespace { out.removeLast() }
        }
        guard !out.isEmpty else { return }
        state.reasoningStarted = true
        continuation.yield(.reasoningDelta(out))
    }

    // MARK: - Harmony (gpt-oss) streaming parser

    /// Streaming parser for OpenAI's **Harmony** response format used by
    /// gpt-oss. The model emits a sequence of channel messages:
    ///   `[<|start|>assistant]<|channel|>CHANNEL[ to=RECIP][ <|constrain|>json]<|message|>CONTENT<term>`
    /// where `<term>` is `<|end|>`, `<|call|>` (tool calls) or
    /// `<|return|>` (final turn). Channels route as: `final` → answer
    /// text, `analysis` → reasoning (hidden by the chat view),
    /// `commentary to=functions.NAME` → a tool call whose CONTENT is the
    /// JSON arguments. mlx-swift-lm has no Harmony tool parser (gpt_oss
    /// falls back to the `<tool_call>` JSON format, which gpt-oss never
    /// emits), so without this the raw tokens leak into the chat.
    private struct HarmonyParser {
        private enum Phase { case header, content }
        private enum Kind: Equatable { case text, reasoning, tool, ignore }

        private var buffer = ""
        private var phase: Phase = .header
        private var kind: Kind = .ignore
        private var toolName = ""
        private var toolArgs = ""

        private static let channel = "<|channel|>"
        private static let message = "<|message|>"
        private static let start = "<|start|>"
        private static let end = "<|end|>"
        private static let call = "<|call|>"
        private static let ret = "<|return|>"
        /// Longest token is `<|constrain|>` (13 chars). Hold back this
        /// many trailing chars so a token split across chunks isn't
        /// emitted as content.
        private static let safeTail = 12

        mutating func consume(
            _ text: String,
            into cont: AsyncThrowingStream<StreamEvent, Error>.Continuation
        ) {
            buffer += text
            while phase == .header ? scanHeader() : scanContent(into: cont) {}
        }

        /// Flushes any trailing content left without a closing token.
        mutating func finish(
            into cont: AsyncThrowingStream<StreamEvent, Error>.Continuation
        ) {
            if phase == .content, !buffer.isEmpty {
                emitContent(buffer, into: cont)
                buffer = ""
            }
            if kind == .tool { finishMessage(into: cont) }
        }

        /// In `.header`: discard structural tokens until a full
        /// `<|channel|>…<|message|>` header is in the buffer, then
        /// configure routing for the message that follows.
        private mutating func scanHeader() -> Bool {
            guard let ch = buffer.range(of: Self.channel) else {
                // No channel marker yet — drop structural text but keep a
                // possible partial `<|channel|>` tail.
                if buffer.count > Self.safeTail {
                    buffer = String(buffer.suffix(Self.safeTail))
                }
                return false
            }
            guard let msg = buffer[ch.upperBound...].range(of: Self.message) else {
                // Header not complete yet — keep from `<|channel|>` on.
                buffer = String(buffer[ch.lowerBound...])
                return false
            }
            // The full header runs from the buffer start (which may hold
            // a `<|start|>assistant to=…` role line) to `<|message|>`.
            configure(region: String(buffer[..<msg.lowerBound]))
            buffer = String(buffer[msg.upperBound...])
            phase = .content
            return true
        }

        /// Configures routing from a header region such as
        /// `<|start|>assistant<|channel|>commentary to=functions.save_memory <|constrain|>json`.
        /// The recipient `to=…` can sit before or after `<|channel|>`,
        /// and the model sometimes runs tokens together without a space
        /// (e.g. `…save_memory<|channel|>commentary<|constrain|>json`),
        /// so identifiers stop at whitespace *or* the start of the next
        /// `<|…|>` token — never letting a marker bleed into a name.
        private mutating func configure(region: String) {
            func ident(_ s: Substring) -> String {
                String(s.prefix { !$0.isWhitespace && $0 != "<" })
            }
            var channelName = ""
            if let ch = region.range(of: Self.channel) {
                channelName = ident(region[ch.upperBound...])
            }
            toolName = ""
            toolArgs = ""
            if let to = region.range(of: "to=") {
                var name = ident(region[to.upperBound...])
                if name.hasPrefix("functions.") {
                    name = String(name.dropFirst("functions.".count))
                }
                toolName = name
            }
            switch channelName {
            case "final": kind = .text
            case "analysis": kind = .reasoning
            default: kind = toolName.isEmpty ? .text : .tool
            }
        }

        /// In `.content`: stream content to the right channel until the
        /// earliest message terminator, then return to `.header`.
        private mutating func scanContent(
            into cont: AsyncThrowingStream<StreamEvent, Error>.Continuation
        ) -> Bool {
            // `<|start|>` / `<|channel|>` begin the *next* message, so
            // leave them in the buffer for the header pass; the others
            // are consumed.
            let consumed = [Self.end, Self.call, Self.ret]
            let kept = [Self.start, Self.channel]
            var hit: (Range<String.Index>, keep: Bool)?
            for (markers, keep) in [(consumed, false), (kept, true)] {
                for m in markers {
                    if let r = buffer.range(of: m), hit == nil || r.lowerBound < hit!.0.lowerBound {
                        hit = (r, keep)
                    }
                }
            }
            guard let hit else {
                // No terminator — flush all but a safe tail.
                if buffer.count > Self.safeTail {
                    let cut = buffer.index(buffer.endIndex, offsetBy: -Self.safeTail)
                    emitContent(String(buffer[..<cut]), into: cont)
                    buffer = String(buffer[cut...])
                }
                return false
            }
            emitContent(String(buffer[..<hit.0.lowerBound]), into: cont)
            finishMessage(into: cont)
            buffer = hit.keep
                ? String(buffer[hit.0.lowerBound...])
                : String(buffer[hit.0.upperBound...])
            phase = .header
            return true
        }

        private mutating func emitContent(
            _ s: String,
            into cont: AsyncThrowingStream<StreamEvent, Error>.Continuation
        ) {
            guard !s.isEmpty else { return }
            switch kind {
            case .text: cont.yield(.textDelta(s))
            case .reasoning: cont.yield(.reasoningDelta(s))
            case .tool: toolArgs += s
            case .ignore: break
            }
        }

        private mutating func finishMessage(
            into cont: AsyncThrowingStream<StreamEvent, Error>.Continuation
        ) {
            if kind == .tool, !toolName.isEmpty {
                let args = toolArgs.trimmingCharacters(in: .whitespacesAndNewlines)
                cont.yield(.toolCall(
                    id: "mlx-" + UUID().uuidString.prefix(8).lowercased(),
                    name: toolName,
                    argumentsJSON: args.isEmpty ? "{}" : args
                ))
            }
            kind = .ignore
            toolName = ""
            toolArgs = ""
        }
    }

    /// Test-only: feeds `chunks` through the streaming marker parser
    /// (mirroring the chat loop, including the end flush) and returns
    /// the events it emits, so think / channel / tool routing can be
    /// asserted without a live model. `gemma == true` uses the Gemma 4
    /// marker set, otherwise the generic `<think>` set.
    /// `preOpenedThink` starts the parser inside the reasoning block, as
    /// `promptOpensReasoning` does for a prompt that prefilled `<think>`.
    static public func collectStreamEventsForTests(
        _ chunks: [String],
        gemma: Bool,
        preOpenedThink: Bool = false
    ) async -> [StreamEvent] {
        let blocks = gemma ? gemma4Blocks : thinkBlocks
        let stream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            var state = StreamState()
            if preOpenedThink { state.block = blocks.first }
            for chunk in chunks {
                processStreamChunk(chunk, blocks: blocks, state: &state, continuation: continuation)
            }
            flushStreamState(&state, continuation: continuation)
            continuation.finish()
        }
        var events: [StreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
        } catch {}
        return events
    }

    /// Test-only: feeds `chunks` through the Harmony (gpt-oss) parser,
    /// including the end flush, and returns the events it emits.
    static public func collectHarmonyEventsForTests(_ chunks: [String]) async -> [StreamEvent] {
        let stream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            var parser = HarmonyParser()
            for chunk in chunks {
                parser.consume(chunk, into: continuation)
            }
            parser.finish(into: continuation)
            continuation.finish()
        }
        var events: [StreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
        } catch {}
        return events
    }

    /// Test-only: the raw Harmony message dicts for gpt-oss, so the
    /// tool-call / tool-result shaping the chat template depends on can
    /// be asserted without a live model.
    static public func mapMessagesHarmonyForTests(_ messages: [ChatMessage]) -> [[String: any Sendable]] {
        mapMessagesHarmony(messages)
    }

    /// Test-only: the number of images attached to each mapped message,
    /// in order — verifies a user message's `imageURLs` reach `UserInput`
    /// without depending on MLX types in the test target.
    static public func mappedImageCountsForTests(_ messages: [ChatMessage]) -> [Int] {
        mapMessages(messages).map(\.images.count)
    }

    /// Test-only re-export so unit tests can hit the parser
    /// without going through the full streaming loop.
    static public func parseGemma4PayloadForTests(_ payload: String) -> (name: String, argumentsJSON: String)? {
        parseGemma4Payload(payload)
    }

    /// Parses a Gemma 4 call payload. Tries the canonical
    /// `call:name{...}` shape first, then the malformed-JSON shape
    /// the model sometimes emits: `{"name":"…","arguments":{"k:<|"|>
    /// v<|"|>}}` (note the missing closing quote on keys + the
    /// `<|"|>` escape marker for string values).
    private static func parseGemma4Payload(_ payload: String) -> (name: String, argumentsJSON: String)? {
        if let result = parseGemma4CallStyle(payload) { return result }
        if let result = parseGemma4JSONStyle(payload) { return result }
        return nil
    }

    /// Canonical Gemma 4 shape: `call:name{key:value, key:<|"|>str<|"|>}`.
    private static func parseGemma4CallStyle(_ payload: String) -> (name: String, argumentsJSON: String)? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("call:") else { return nil }
        let afterCall = trimmed.dropFirst("call:".count)
        guard let openBrace = afterCall.firstIndex(of: "{"),
              let closeBrace = afterCall.lastIndex(of: "}"),
              closeBrace > openBrace
        else { return nil }

        let name = String(afterCall[..<openBrace])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        let args = parseGemma4ArgsBody(afterCall[afterCall.index(after: openBrace)..<closeBrace])

        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8)
        else { return nil }
        return (name, json)
    }

    /// Tokenises a Gemma 4 argument body — `key:value, key:<|"|>str<|"|>`
    /// — into a dictionary. String values are wrapped in the `<|"|>`
    /// escape marker and may contain commas, colons and braces, so we
    /// can't naively split. Keys may be bare (`k`), half-quoted (`"k`)
    /// or fully quoted (`"k"`) depending on the model's mood; we strip
    /// the surrounding quotes either way.
    private static func parseGemma4ArgsBody(_ argsBody: Substring) -> [String: Any] {
        let escape = "<|\"|>"
        var args: [String: Any] = [:]
        var remaining = argsBody
        while !remaining.isEmpty {
            // Trim leading whitespace / commas.
            while let first = remaining.first, first == "," || first.isWhitespace {
                remaining = remaining.dropFirst()
            }
            guard let colon = remaining.firstIndex(of: ":") else { break }
            var key = String(remaining[..<colon])
                .trimmingCharacters(in: .whitespaces)
            // The model balances key quotes inconsistently.
            if key.hasPrefix("\"") { key.removeFirst() }
            if key.hasSuffix("\"") { key.removeLast() }
            remaining = remaining[remaining.index(after: colon)...]
            while let first = remaining.first, first.isWhitespace {
                remaining = remaining.dropFirst()
            }
            guard !key.isEmpty else { break }

            if remaining.hasPrefix(escape) {
                // String between `<|"|>` escape markers.
                let afterOpen = remaining.dropFirst(escape.count)
                guard let endRange = afterOpen.range(of: escape) else { break }
                args[key] = String(afterOpen[..<endRange.lowerBound])
                remaining = afterOpen[endRange.upperBound...]
            } else if remaining.hasPrefix("\"") {
                // Plainly-quoted string (keys broken, value intact).
                let afterOpen = remaining.dropFirst()
                guard let endQuote = afterOpen.firstIndex(of: "\"") else { break }
                args[key] = String(afterOpen[..<endQuote])
                remaining = afterOpen[afterOpen.index(after: endQuote)...]
            } else {
                // Bare value until the next comma.
                let endIdx = remaining.firstIndex(of: ",") ?? remaining.endIndex
                let raw = String(remaining[..<endIdx])
                    .trimmingCharacters(in: .whitespaces)
                // Best-effort type coercion: number, bool, else string.
                if let i = Int(raw) {
                    args[key] = i
                } else if let d = Double(raw) {
                    args[key] = d
                } else if raw == "true" {
                    args[key] = true
                } else if raw == "false" {
                    args[key] = false
                } else {
                    args[key] = raw
                }
                remaining = endIdx == remaining.endIndex ? "" : remaining[remaining.index(after: endIdx)...]
            }
        }
        return args
    }

    /// JSON-ish shape Gemma 4 sometimes emits:
    ///   `{"name":"foo","arguments":{"k:<|"|>v<|"|>,k2:<|"|>w<|"|>}}`
    /// Notable malformations the model produces in this mode:
    /// - Keys lose quotes erratically: the first may keep its opening
    ///   `"` (from `{"`), later ones drop both (`,k:` not `,"k":`).
    /// - String values are wrapped in `<|"|>…<|"|>` instead of `"…"`,
    ///   and the values are free-form (commas, colons, braces).
    /// Rather than regex-patch this back into valid JSON — fragile
    /// once the escapes are unwrapped — we extract the name and the
    /// arguments body and hand the body to the same escape-aware
    /// tokeniser the `call:` style uses.
    private static func parseGemma4JSONStyle(_ payload: String) -> (name: String, argumentsJSON: String)? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("\"name\"") else { return nil }

        guard let name = extractGemma4StringValue(forKey: "name", in: trimmed),
              !name.isEmpty,
              let argsBody = extractGemma4ArgumentsBody(in: trimmed)
        else { return nil }

        let args = parseGemma4ArgsBody(argsBody)
        guard let argsData = try? JSONSerialization.data(withJSONObject: args),
              let argsJSON = String(data: argsData, encoding: .utf8)
        else { return nil }
        return (name, argsJSON)
    }

    /// Reads the string value for `"<key>":` — quoted plainly (`"v"`)
    /// or with the `<|"|>` escape marker.
    private static func extractGemma4StringValue(forKey key: String, in payload: String) -> String? {
        guard let keyRange = payload.range(of: "\"\(key)\"") else { return nil }
        let afterKey = payload[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        var rest = afterKey[afterKey.index(after: colon)...]
        while let first = rest.first, first.isWhitespace { rest = rest.dropFirst() }

        let escape = "<|\"|>"
        if rest.hasPrefix(escape) {
            let afterOpen = rest.dropFirst(escape.count)
            guard let end = afterOpen.range(of: escape) else { return nil }
            return String(afterOpen[..<end.lowerBound])
        }
        guard rest.hasPrefix("\"") else { return nil }
        let afterOpen = rest.dropFirst()
        guard let end = afterOpen.firstIndex(of: "\"") else { return nil }
        return String(afterOpen[..<end])
    }

    /// Returns the body inside the `"arguments":{ … }` object, brace-
    /// matched while skipping over `<|"|>…<|"|>` escaped regions so
    /// that braces inside free-form string values don't fool us.
    private static func extractGemma4ArgumentsBody(in payload: String) -> Substring? {
        guard let argsKey = payload.range(of: "\"arguments\"") else { return nil }
        let scope = payload[argsKey.upperBound...]
        guard let open = scope.firstIndex(of: "{") else { return nil }

        let escape = "<|\"|>"
        var depth = 0
        var insideEscape = false
        var i = open
        while i < scope.endIndex {
            if scope[i...].hasPrefix(escape) {
                insideEscape.toggle()
                i = scope.index(i, offsetBy: escape.count)
                continue
            }
            if !insideEscape {
                switch scope[i] {
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return scope[scope.index(after: open)..<i]
                    }
                default: break
                }
            }
            i = scope.index(after: i)
        }
        return nil
    }

    /// Wraps a TyKaoz `ToolSpec` in the OpenAI-style schema dict
    /// mlx-swift-lm expects (`{"type": "function", "function": {...}}`).
    /// Returns `nil` if the input JSON schema can't be parsed —
    /// those tools just don't get advertised to the model, rather
    /// than failing the whole turn.
    private static func mapTool(_ spec: KaozKit.ToolSpec) -> MLXLMCommon.ToolSpec? {
        guard let data = spec.inputSchemaJSON.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let schema = parsed as? [String: Any]
        else { return nil }
        return [
            "type": "function",
            "function": [
                "name": spec.name,
                "description": spec.description,
                "parameters": schema,
            ] as [String: any Sendable],
        ]
    }
}
