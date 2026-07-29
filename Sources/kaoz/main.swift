import Foundation
import KaozKit
import KaozMLX

// kaoz — runs a standalone JavaScript agent headless on top of KaozKit.
//
// Usage:
//   kaoz <agent.js> [--provider anthropic|local] [--model M]
//             [--input JSON] [--library DIR] [--timeout SEC] [--root DIR ...]
//             [--modules nom=dir ...]
//
// Modules resolve Moddable-style: the agent's own directory is the default
// root, so `import "sub-agent"` (no `./`, no extension — `.xsb`/`.mjs`/`.js`
// searched) finds a sibling. `--modules nom=dir` adds a named root
// (`import "nom/x"`). Resolution is confined to the roots.
//
// Provider config comes from the environment:
//   anthropic: ANTHROPIC_API_KEY (+ --model / TYKAOZ_MODEL)
//   local:     TYKAOZ_LOCAL_BASE_URL (default http://localhost:1234/v1),
//              TYKAOZ_LOCAL_API_KEY (optional), --model / TYKAOZ_MODEL
//   BRAVE_API_KEY (optional) enables the web_search tool.
//
// The agent's result is printed to stdout as a JSON string; errors go to
// stderr with a non-zero exit.

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// MARK: - Argument parsing

var args = Array(CommandLine.arguments.dropFirst())
func popFlag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}
/// Collect every occurrence of a repeatable flag (e.g. `--root A --root B`).
func popFlagAll(_ name: String) -> [String] {
    var values: [String] = []
    while let value = popFlag(name) { values.append(value) }
    return values
}
/// A boolean flag (present/absent), removed from `args`.
func popBool(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let providerName = popFlag("--provider") ?? "anthropic"
let model = popFlag("--model") ?? ProcessInfo.processInfo.environment["TYKAOZ_MODEL"]
let inputJSON = popFlag("--input")
let libraryDir = popFlag("--library")
let timeout = TimeInterval(popFlag("--timeout") ?? "") ?? 60
// Resident mode: keep one engine alive and deliver a JSON message per stdin
// line to the agent's handler (onMessage), printing each result. Engine + JS
// heap persist between messages (state survives across turns).
let resident = popBool("--resident")
// Persist the resident agent's JS heap across processes: restore from this file
// on start (if it exists), snapshot back to it on exit. Implies a non-threaded
// engine (snapshot-capable).
let statePath = popFlag("--state")
// Daemon: after the initial --input message, stay alive so the agent's own
// scheduled ticks (host.schedule/every) keep firing. Still reads stdin for more
// messages in the background. Runs until killed (Ctrl-C).
let daemon = popBool("--daemon")

// Module roots (Moddable-style): named external roots the agent imports from
// with `import "nom/module"`. Each `--modules nom=dir` maps a prefix to a dir;
// the agent's own directory is always the default root (registered below).
let namedModuleRoots: [(prefix: String, dir: String)] = popFlagAll("--modules").compactMap {
    guard let eq = $0.firstIndex(of: "=") else { return nil }
    let dir = String($0[$0.index(after: eq)...])
    return (String($0[..<eq]), URL(fileURLWithPath: dir, isDirectory: true).path)
}

// File-space tools: each `--root DIR` authorises a folder the agent may read.
// The CLI has no sandbox, so an AuthorizedRoot is a plain directory URL (the
// tools' security-scoped bracketing is a no-op on non-scoped URLs).
let fileRoots: [AuthorizedRoot] = popFlagAll("--root").map { path in
    let url = URL(fileURLWithPath: path, isDirectory: true)
    return AuthorizedRoot(name: url.lastPathComponent, url: url)
}

// Actuation (opt-in, confined). `--allow-write DIR` authorises writable folders
// for write_file/edit_file (a separate grant from --root read access);
// `--allow-shell` grants run_shell in `--shell-dir` (default: current dir).
// Parsed here, before the script path, so the flags aren't mistaken for it.
let writeRoots: [AuthorizedRoot] = popFlagAll("--allow-write").map { path in
    let url = URL(fileURLWithPath: path, isDirectory: true)
    return AuthorizedRoot(name: url.lastPathComponent, url: url)
}
let allowShell = popBool("--allow-shell")
let shellDir = popFlag("--shell-dir")
// Hard token budget (prompt+completion) across the run; further host.llm.chat
// calls reject once exceeded. The agent can also read host.usage() to self-limit.
let tokenBudget = popFlag("--budget").flatMap { Int($0) }
// Persona / SOUL file: its text is prepended as the base system message of every
// host.llm.chat, giving the agent a stable identity + standing instructions.
let persona = popFlag("--persona").flatMap {
    try? String(contentsOf: URL(fileURLWithPath: $0), encoding: .utf8)
}

// Channels (Phase 5). `--allow-http [--http-host H ...]` enables the outbound
// http_request tool (optionally host-restricted). `--webhook PORT` runs an
// inbound HTTP server that delivers each request body to the resident agent and
// replies with its result (implies resident + daemon).
let httpHosts = popFlagAll("--http-host")
let allowHTTP = popBool("--allow-http") || !httpHosts.isEmpty
let webhookPort = popFlag("--webhook").flatMap { UInt16($0) }
// Email (Proton Bridge by default): `--email` enables send_email/read_email
// over local IMAP/SMTP. Credentials from env (the Bridge shows them):
// PROTON_BRIDGE_USER / _PASS / _FROM (+ optional _HOST / _SMTP_PORT / _IMAP_PORT).
let allowEmail = popBool("--email")

// Dev harness for the native __http primitive + XMLHttpRequest shim (C1): runs
// a bare engine (no provider/LLM) and prints the JSON on `globalThis.__result`.
if let probePath = popFlag("--http-eval") {
    guard let probeSrc = try? String(contentsOf: URL(fileURLWithPath: probePath), encoding: .utf8) else {
        die("error: cannot read --http-eval script at \(probePath)")
    }
    print(JSHttpProbe.run(script: probeSrc, timeout: timeout) ?? "null")
    exit(0)
}

// Multi-agent runs are initiated from the script itself: an agent calls
// `new Thread()` + `new Service(thread, "sub-agent")` and `await`s the
// sub-agent's default-export methods (see AgentRuntime / TyKaozThreads). The
// sub-agent module resolves against the process-wide roots, like any import.

guard let scriptPath = args.first else {
    die("""
        usage: kaoz <agent.js> [--provider anthropic|local] [--model M] \
        [--input JSON] [--library DIR] [--timeout SEC] [--root DIR ...] \
        [--modules nom=dir ...] [--resident [--daemon] [--state FILE]] \
        [--allow-write DIR ...] [--allow-shell [--shell-dir DIR]] \
        [--allow-http [--http-host H ...]] [--webhook PORT] [--budget TOKENS] \
        [--email] [--persona FILE]
        """, code: 2)
}

guard FileManager.default.isReadableFile(atPath: scriptPath) else {
    die("error: cannot read agent script at \(scriptPath)")
}

let env = ProcessInfo.processInfo.environment

// MARK: - Provider (built lazily, off the XS thread)

// Resolve any provider by id, with JS-supplied options (`model`, `baseURL`)
// overriding the CLI defaults. Secrets (API keys) come from the environment
// here — never from JS. This backs both the run default (`--provider`) and the
// per-call `host.provider(id, {model})` selection from JavaScript.
let resolveProvider: @Sendable (String, [String: Any]) -> (any LLMProvider)? = { id, options in
    let model = (options["model"] as? String) ?? model
    func base(_ envKey: String) -> String? { (options["baseURL"] as? String) ?? env[envKey] }
    switch id {
    case "anthropic":
        guard let key = env["ANTHROPIC_API_KEY"], !key.isEmpty, let model, !model.isEmpty else {
            return nil
        }
        return AnthropicProvider(apiKey: key, model: model)
    case "js-anthropic":
        guard let key = env["ANTHROPIC_API_KEY"], !key.isEmpty, let model, !model.isEmpty else {
            return nil
        }
        return JSProviders.anthropic(apiKey: key, model: model, baseURL: base("ANTHROPIC_BASE_URL"))
    case "js-openai":
        guard let key = env["OPENAI_API_KEY"], !key.isEmpty, let model, !model.isEmpty else {
            return nil
        }
        return JSProviders.openai(apiKey: key, model: model, baseURL: base("OPENAI_BASE_URL"))
    case "js-ollama":
        guard let model, !model.isEmpty else { return nil }
        return JSProviders.ollama(
            model: model, baseURL: base("OLLAMA_BASE_URL") ?? "http://localhost:11434")
    case "js-google":
        guard let key = env["GOOGLE_API_KEY"] ?? env["GOOGLEAI_API_KEY"], !key.isEmpty,
              let model, !model.isEmpty else {
            return nil
        }
        return JSProviders.google(apiKey: key, model: model, baseURL: base("GOOGLE_BASE_URL"))
    case "mimo":
        guard let key = env["MIMO_API_KEY"] ?? env["XIAOMI_API_KEY"], !key.isEmpty,
              let model, !model.isEmpty else {
            return nil
        }
        return MiMoProvider(
            apiKey: key, model: model,
            baseURL: base("MIMO_BASE_URL").flatMap(URL.init(string:)) ?? MiMoProvider.baseURL)
    case "js-mimo":
        guard let key = env["MIMO_API_KEY"] ?? env["XIAOMI_API_KEY"], !key.isEmpty,
              let model, !model.isEmpty else {
            return nil
        }
        return JSProviders.mimo(apiKey: key, model: model, baseURL: base("MIMO_BASE_URL"))
    case "kimi":
        guard let key = env["MOONSHOT_API_KEY"] ?? env["KIMI_API_KEY"], !key.isEmpty else {
            return nil
        }
        return KimiProvider(
            apiKey: key, model: model ?? KimiProvider.defaultModel,
            baseURL: base("KIMI_BASE_URL").flatMap(URL.init(string:)) ?? KimiProvider.baseURL)
    case "js-kimi":
        guard let key = env["MOONSHOT_API_KEY"] ?? env["KIMI_API_KEY"], !key.isEmpty else {
            return nil
        }
        return JSProviders.kimi(apiKey: key, model: model ?? "kimi-k3", baseURL: base("KIMI_BASE_URL"))
    case "local":
        let b = base("TYKAOZ_LOCAL_BASE_URL") ?? "http://localhost:1234/v1"
        guard let url = URL(string: b), let model, !model.isEmpty else { return nil }
        return LocalOpenAIProvider(
            baseURL: url, apiKey: env["TYKAOZ_LOCAL_API_KEY"] ?? "", model: model)
    case "apple":
        return AppleIntelligenceProvider()
    case "mlx":
        // MLX needs its Metal library, which `swift build` doesn't produce for a
        // CLI — run `scripts/link-mlx-metallib.sh` after building (see the script).
        guard let model, !model.isEmpty else { return nil }
        return MLXLLMProvider(modelID: model)
    default:
        return nil
    }
}
// The run default (the `--provider` flag), and the catalog JS discovers via
// host.providers().
let makeProvider: @Sendable () -> (any LLMProvider)? = { resolveProvider(providerName, [:]) }
// `model` = the CLI default (--model / TYKAOZ_MODEL), what host.provider(id)
// resolves to when JS omits a model — so an element is directly instantiable.
let providerCatalog: [ProviderDescriptor] = [
    .init(id: "anthropic", name: "Anthropic", model: model),
    .init(id: "js-anthropic", name: "Anthropic (JS)", model: model),
    .init(id: "js-openai", name: "OpenAI-compatible (JS)", model: model),
    .init(id: "js-ollama", name: "Ollama (JS)", model: model),
    .init(id: "js-google", name: "Google Gemini (JS)", model: model),
    .init(id: "kimi", name: "Kimi (Moonshot)", model: model ?? KimiProvider.defaultModel),
    .init(id: "js-kimi", name: "Kimi K3 (JS)", model: model ?? KimiProvider.defaultModel),
    .init(id: "mimo", name: "Xiaomi MiMo", model: model ?? "mimo-v2.5-pro"),
    .init(id: "js-mimo", name: "Xiaomi MiMo (JS)", model: model ?? "mimo-v2.5-pro"),
    .init(id: "local", name: "Local OpenAI", model: model),
    .init(id: "apple", name: "Apple Intelligence"),
    .init(id: "mlx", name: "MLX", model: model),
]

// MARK: - Tools + memory (top-level code in main.swift is @MainActor)

let memoryURL = URL(fileURLWithPath: env["TYKAOZ_MEMORY_FILE"]
    ?? (NSHomeDirectory() + "/.tykaoz/cli-memories.json"))
// Semantic memory: host.memory.search ranks notes by embedding similarity.
// Default embedder is dependency-free (lexical); --embed-ollama MODEL uses a
// real embedding model (needs a running Ollama) for true semantic recall.
let embedder: any EmbeddingProvider = {
    if let model = popFlag("--embed-ollama"), !model.isEmpty,
       let base = URL(string: env["OLLAMA_BASE_URL"] ?? "http://localhost:11434") {
        return OllamaEmbeddingProvider(baseURL: base, modelID: model, dimension: 768)
    }
    return HashingEmbeddingProvider()
}()
let memory = SemanticMemoryStore(fileURL: memoryURL, embedder: embedder)

// Native (OS-bound) tools: memory + files stay in Swift.
var tools: [any Tool] = [
    SaveMemoryTool(store: memory),
    ListMemoriesTool(store: memory),
    ReadMemoryTool(store: memory),
]
if !fileRoots.isEmpty {
    tools.append(ListDirectoryTool(roots: fileRoots))
    tools.append(ReadFileTool(roots: fileRoots))
    tools.append(GrepFilesTool(roots: fileRoots))
}
// Actuation (opt-in). Write/edit confined to --allow-write folders; shell in
// its own working directory.
if !writeRoots.isEmpty {
    tools.append(WriteFileTool(roots: writeRoots))
    tools.append(EditFileTool(roots: writeRoots))
}
if allowShell {
    let cwd = shellDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    tools.append(ShellTool(workingDirectory: cwd, timeout: timeout))
}
if allowHTTP {
    tools.append(HTTPRequestTool(allowedHosts: httpHosts.isEmpty ? nil : httpHosts))
}
if allowEmail {
    let emailConfig = EmailConfig(
        host: env["PROTON_BRIDGE_HOST"] ?? "127.0.0.1",
        smtpPort: Int(env["PROTON_BRIDGE_SMTP_PORT"] ?? "") ?? 1025,
        imapPort: Int(env["PROTON_BRIDGE_IMAP_PORT"] ?? "") ?? 1143,
        username: env["PROTON_BRIDGE_USER"] ?? "",
        password: env["PROTON_BRIDGE_PASS"] ?? "",
        fromAddress: env["PROTON_BRIDGE_FROM"] ?? env["PROTON_BRIDGE_USER"] ?? "",
        // Proton Bridge: SMTP = implicit TLS (ssl), IMAP = STARTTLS. Override each
        // with PROTON_BRIDGE_SMTP_TLS / _IMAP_TLS = ssl | starttls | none.
        smtpTLS: EmailConfig.TLSMode(rawValue: env["PROTON_BRIDGE_SMTP_TLS"] ?? "ssl") ?? .ssl,
        imapTLS: EmailConfig.TLSMode(rawValue: env["PROTON_BRIDGE_IMAP_TLS"] ?? "starttls") ?? .starttls)
    tools.append(SendEmailTool(config: emailConfig))
    tools.append(ReadEmailTool(config: emailConfig))
}
// HTTP / pure tools are JS modules (datetime, fetch_url, web_search).
var jsToolNames = ["datetime", "fetch-url"]
var toolConfig: [String: Any] = [:]
if let brave = env["BRAVE_API_KEY"], !brave.isEmpty {
    jsToolNames.append("web-search")
    toolConfig["braveApiKey"] = brave
    if let base = env["BRAVE_BASE_URL"], !base.isEmpty { toolConfig["braveBaseURL"] = base }
}
if let jsTools = JSToolBundle(
    toolModules: jsToolNames, config: toolConfig,
    tools: ToolRegistry(tools: []), memory: memory) {
    tools.append(contentsOf: jsTools.tools())
}
let registry = ToolRegistry(tools: tools)

// MARK: - Run

let runtime = AgentRuntime(
    makeProvider: makeProvider,
    resolveProvider: resolveProvider,
    providerCatalog: providerCatalog,
    tools: registry,
    memory: memory,
    tokenBudget: tokenBudget,
    persona: persona,
    log: { FileHandle.standardError.write(Data("[log] \($0)\n".utf8)) })

// Malformed --input must fail here: silently passing null would surface much
// later as a confusing "cannot coerce null to object" inside the agent.
let input: Any? = inputJSON.map {
    guard let parsed = try? JSONSerialization.jsonObject(
        with: Data($0.utf8), options: [.fragmentsAllowed]) else {
        die("error: --input is not valid JSON: \($0)")
    }
    return parsed
}

// Module roots (Moddable-style): the agent's own directory is the default
// root, so `import "sub-agent"` finds a sibling `sub-agent.{xsb,mjs,js}`; a
// `new Service(t, "sub-agent")` sub-agent resolves the same way (roots are
// process-wide). `--library DIR` adds another default root; `--modules nom=dir`
// adds named roots (`import "nom/x"`). Resolution is confined to the roots.
let scriptURL = URL(fileURLWithPath: scriptPath)
let entryModule = scriptURL.deletingPathExtension().lastPathComponent
var moduleRoots: [(prefix: String, dir: String)] = [
    ("", scriptURL.deletingLastPathComponent().path)
]
if let libraryDir {
    moduleRoots.append(("", URL(fileURLWithPath: libraryDir, isDirectory: true).path))
}
moduleRoots.append(contentsOf: namedModuleRoots)

// Retains the webhook server for the daemon's lifetime (assigned inside the
// resident branch; a top-level var outlives that scope's parked await).
var retainedWebhook: WebhookServer?

/// One-shot latch guarding the daemon's shutdown: signal handlers run on a
/// concurrent queue, so a second Ctrl-C must be told apart from the first.
final class ShutdownFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    /// True only for the first caller.
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if started { return false }
        started = true
        return true
    }
}

if resident {
    // A resident agent: one engine, many deliveries. Read a JSON message per
    // stdin line, deliver it, print the handler's JSON result. State persists.
    let logSink: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data("[log] \($0)\n".utf8))
    }
    let restored = statePath.flatMap { p -> Data? in
        FileManager.default.fileExists(atPath: p)
            ? try? Data(contentsOf: URL(fileURLWithPath: p)) : nil
    }
    let agentOpt: AgentHost? = restored.map { data in
        AgentHost(
            snapshot: data, roots: moduleRoots, name: entryModule,
            makeProvider: makeProvider, resolveProvider: resolveProvider,
            providerCatalog: providerCatalog, tools: registry, memory: memory,
            tokenBudget: tokenBudget, persona: persona, log: logSink)
    } ?? AgentHost(
        entryModule: entryModule, roots: moduleRoots,
        makeProvider: makeProvider, resolveProvider: resolveProvider,
        providerCatalog: providerCatalog, tools: registry, memory: memory,
        tokenBudget: tokenBudget, persona: persona,
        installThreads: statePath == nil,   // snapshot-capable (no threads) when persisting
        log: logSink)
    guard let agent = agentOpt else {
        die("error: cannot create resident agent")
    }
    // Line-buffer stdout so results appear promptly even when piped (a daemon is
    // killed, not exited, so block buffering would swallow its output).
    setvbuf(stdout, nil, _IOLBF, 0)

    // Persist the JS heap (state) for the next process, if requested.
    let snapshotPath = statePath
    let persistState: @Sendable () -> Void = {
        guard let snapshotPath else { return }
        // A snapshot needs an idle machine: in-flight host calls (an LLM turn, a
        // tool) are parked in Swift, off the heap, so writing now would fail and
        // lose everything. Let them settle — Ctrl-C mid-answer is the common case.
        if agent.pendingCount > 0 {
            FileHandle.standardError.write(Data(
                "[daemon] settling in-flight work before snapshot — Ctrl-C again to abandon\n".utf8))
            let deadline = Date().addingTimeInterval(timeout)
            while agent.pendingCount > 0, Date() < deadline { usleep(20_000) }
        }
        do {
            try agent.writeSnapshot().write(to: URL(fileURLWithPath: snapshotPath))
        } catch {
            FileHandle.standardError.write(
                Data("snapshot failed: \(error.localizedDescription)\n".utf8))
        }
    }

    // A daemon ends by signal, not by EOF: catch SIGINT/SIGTERM so the snapshot
    // is written before we go away — the default handler kills the process
    // before any of the code below can run.
    var signalSources: [any DispatchSourceSignal] = []
    if snapshotPath != nil {
        let shutdown = ShutdownFlag()
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                guard shutdown.begin() else {
                    // Second signal: the work we were waiting on may never settle.
                    FileHandle.standardError.write(
                        Data("[daemon] abandoned — no snapshot written\n".utf8))
                    exit(1)
                }
                // Settle-and-write off the handler: a source serializes its
                // events, so blocking here would swallow the second Ctrl-C.
                DispatchQueue.global().async {
                    persistState()
                    agent.close()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
    _ = signalSources   // keep the sources alive for the process's lifetime

    // Inbound channel: an HTTP server that delivers each request body to the
    // agent and replies with its result. Keeps the process alive (implies daemon).
    var webhookServer: WebhookServer?
    if let webhookPort {
        webhookServer = try? WebhookServer(port: webhookPort) { bodyData in
            let payload: Any = (try? JSONSerialization.jsonObject(
                with: bodyData, options: [.fragmentsAllowed]))
                ?? (String(data: bodyData, encoding: .utf8) ?? "")
            let result = (try? await agent.deliver(
                kind: "message", payload: payload, timeout: timeout))
                ?? #"{"error":"agent delivery failed"}"#
            return Data(result.utf8)
        }
        if webhookServer != nil {
            webhookServer?.start()
            FileHandle.standardError.write(Data("[webhook] listening on :\(webhookPort)\n".utf8))
        } else {
            FileHandle.standardError.write(Data("webhook: failed to bind :\(webhookPort)\n".utf8))
        }
    }

    let deliverMessage: (Any) async -> Void = { payload in
        do {
            print(try await agent.deliver(kind: "message", payload: payload, timeout: timeout))
        } catch {
            FileHandle.standardError.write(
                Data("error: \(error.localizedDescription)\n".utf8))
        }
    }
    let parseLine: (String) -> Any? = { line in
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        return t.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed])
        } ?? t
    }

    if daemon || webhookServer != nil {
        // Proactive / channel-driven agent: kick it once (via --input), then stay
        // alive so its scheduled ticks (host.schedule/every) fire and the webhook
        // server keeps serving. Reads more stdin messages in the background.
        if let input { await deliverMessage(input) }
        // readLine() blocks, so it needs its own thread. A `Task {}` here would
        // inherit this scope's @MainActor and pin the main thread between two
        // typed lines — and every async host call settles from
        // `Task { @MainActor }` (TyKaozHost), so a tick firing while the
        // terminal waits for input could never complete. Its host call would
        // stay in flight forever, blocking the snapshot with it.
        let stdinThread = Thread {
            while let line = readLine(strippingNewline: true) {
                guard let payload = parseLine(line) else { continue }
                // One delivery at a time, as the previous sequential loop did.
                let delivered = DispatchSemaphore(value: 0)
                Task.detached {
                    await deliverMessage(payload)
                    delivered.signal()
                }
                delivered.wait()
            }
        }
        stdinThread.stackSize = 1 << 20
        stdinThread.start()
        retainedWebhook = webhookServer   // keep the listener alive past this scope
        FileHandle.standardError.write(Data("[daemon] running — Ctrl-C to stop\n".utf8))
        // Park without blocking a thread (timers + the webhook run on their own
        // queues, deliveries on the concurrency pool). Runs until killed — the
        // signal handler above exits the process. A never-resumed continuation
        // parks just as well, but the checked runtime reports it as a leak on
        // stderr the moment we suspend.
        while true { try? await Task.sleep(for: .seconds(3600)) }
    }

    while let line = readLine(strippingNewline: true) {
        if let payload = parseLine(line) { await deliverMessage(payload) }
    }
    persistState()
    agent.close()
    exit(0)
}

do {
    let result = try await runtime.runRooted(
        entryModule: entryModule,
        roots: moduleRoots,
        input: input,
        timeout: timeout)
    print(result)
} catch {
    die("error: \(error.localizedDescription)")
}
