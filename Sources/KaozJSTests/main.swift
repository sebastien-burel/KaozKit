// KaozJSTests — phase runner / test harness.
// Runs each phase's criteria, prints "PHASE n: PASS|FAIL", and exits non-zero
// if any criterion fails (usable in CI / non-interactive runs — PLAN annex).

import KaozJSCore      // C module — GC/leak/print introspection (test-only)
import KaozJS   // Swift API — XSEngine
import KaozJSTestC // C side of the demo host (installs host.*)
import Darwin
import Foundation

// Test instrumentation over the flat C API — not part of the consumer surface
// of KaozJS, so it lives here, built on withMachine + pendingCount.
extension XSEngine {
    /// Like runUntilIdle, but forces a full GC on the XS thread every turn —
    /// stresses the rooting of in-flight resolve/reject/onToken slots (Phase 5).
    func runUntilIdleForcingGC(timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingCount > 0 {
            withMachine { xsBridgeCollectGarbage($0) }
            if Date() > deadline { break }
            usleep(2_000)
        }
    }

    /// (remembered, forgotten) — equal when idle if no slot leaked.
    var rememberForgetCounts: (UInt32, UInt32) {
        withMachine {
            var remembered: UInt32 = 0
            var forgotten: UInt32 = 0
            xsBridgeDebugCounts($0, &remembered, &forgotten)
            return (remembered, forgotten)
        }
    }

    /// Values passed to JS `print()` since the last install (capture lives in
    /// KaozJSTestC; written on the XS thread, so read there via withMachine).
    var outputs: [String] {
        withMachine { _ in
            let n = Int(xsBridgeTestOutputCount())
            return (0..<n).compactMap {
                xsBridgeTestOutputAt(Int32($0)).map { String(cString: $0) }
            }
        }
    }
}

var failures = 0

/// A fresh engine with the demo host functions installed (CLI-style: the C
/// target registers host.echo/stream/fail/add, which call back into Swift).
func makeEngine() -> XSEngine? {
    guard let engine = XSEngine() else { return nil }
    engine.withMachine { xsBridgeTestInstall($0) }
    return engine
}

// Register the harness thread factory once: JS `new Thread(...)` spawns a child
// engine through it (see PHASE 7).
DemoThreads.register()

func check(_ label: String, _ condition: Bool) {
    print("  [\(condition ? "ok" : "XX")] \(label)")
    if !condition { failures += 1 }
}

func phaseResult(_ n: Int, _ before: Int) {
    let ok = failures == before
    print("PHASE \(n): \(ok ? "PASS" : "FAIL")")
}

/// Current resident memory in bytes — used to eyeball leaks across the stress loop.
func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

/// Bytes currently allocated across every malloc zone. Unlike RSS this ignores
/// freed-but-still-mapped regions, so it does not move with the allocator's
/// large-block cache — which is what made the Phase 1 leak guard erratic.
func allocatedBytes() -> UInt64 {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)   // nil = aggregate of every zone
    return UInt64(stats.size_in_use)
}

// ---- Phase 1: machine lifecycle + synchronous eval ----
do {
    let before = failures
    print("PHASE 1 — machine lifecycle + sync eval")

    guard let engine = makeEngine() else {
        check("create machine", false)
        phaseResult(1, before)
        exit(1)
    }

    // eval returns a value
    if let r = try? engine.eval("6 * 7") {
        check("eval(\"6 * 7\") == 42", r == "42")
    } else {
        check("eval(\"6 * 7\") == 42", false)
    }

    // eval throwing is caught and returned as an error — process survives
    do {
        _ = try engine.eval("throw new Error('boom')")
        check("eval(throw) reported as error", false)
    } catch let e as XSError {
        check("eval(throw) reported as error (\(e.message))", e.message.range(of: "boom") != nil)
    } catch {
        check("eval(throw) reported as error", false)
    }

    // process is still alive and the same machine still works after the throw
    check("machine usable after exception", (try? engine.eval("1 + 1")) == "2")

    // N create/delete cycles — no crash, no leak.
    // Count overridable via XSB_MACHINE_ITERS (used by the Phase 5 stress test).
    let iters = ProcessInfo.processInfo.environment["XSB_MACHINE_ITERS"].flatMap { Int($0) } ?? 1000

    func cycle() -> Bool {
        guard let e = makeEngine() else { return false }
        return (try? e.eval("({a:1,b:2})")) != nil
        // e released here -> xsBridgeDeleteMachine
    }

    // Warm up so the one-time high-water marks are established before measuring:
    // a machine is a 16 MB chunk plus its slot heap, and the first few cycles
    // are what make the allocator claim those regions. The leak test is then
    // growth ACROSS the loop, which must stay flat — a true per-machine leak
    // would scale with `iters` (hundreds of MB over 1000).
    for _ in 0..<50 { _ = cycle() }

    // Measure allocated bytes, NOT RSS. A machine's 16 MB chunk is a malloc
    // allocation, so freeing it hands the region back to libmalloc — which
    // keeps it mapped and resident in its large-block cache rather than
    // returning it to the OS. `vmmap` names those regions outright: across one
    // loop, MALLOC_LARGE (empty) went from 48 MB / 3 regions to 64 MB / 4, one
    // more region of exactly initialChunkSize. Empty, i.e. already freed.
    //
    // RSS counts them all the same, so it measured allocator policy as much as
    // engine usage: release runs read anywhere from +0.1 to +64.5 MB while
    // debug read flat, making any fixed threshold a coin flip.
    // malloc_zone_pressure_relief does not reclaim them either. Allocated bytes
    // ignore freed regions by construction, which is exactly the property this
    // guard needs. (The residue is not thread stacks: the same vmmap shows 5
    // Stack regions totalling 160 KB resident, and shrinking the stacks to 1 MB
    // left the 16 MB step untouched.)
    //
    // Settling is still required — `cycle` returns when the last reference
    // drops, but each engine tears its machine down on its own thread, and a
    // machine mid-teardown genuinely still owns its chunk. Wait for the reading
    // to stop moving rather than sleeping a fixed amount. Equality is too
    // strict (the Swift runtime allocates under our feet), hence the tolerance;
    // the attempt cap keeps a real leak from stalling the suite, since it would
    // never settle and the assertion below is what must catch it.
    func steadyAllocated() -> UInt64 {
        var last: UInt64 = 0
        for attempt in 0..<20 {
            Thread.sleep(forTimeInterval: 0.1)
            let now = allocatedBytes()
            let drift = now > last ? now - last : last - now   // UInt64: no negatives
            if attempt > 0, drift < 64 * 1024 { return now }
            last = now
        }
        return last
    }

    let allocBefore = steadyAllocated()
    let rssBefore = residentBytes()
    var loopOK = true
    for _ in 0..<iters {
        if !cycle() { loopOK = false; break }
    }
    let allocAfter = steadyAllocated()
    let rssAfter = residentBytes()
    check("\(iters) machine create/eval/delete cycles", loopOK)
    let mb: Double = 1_048_576
    let growthMB: Double = (Double(allocAfter) - Double(allocBefore)) / mb
    print(String(format: "  allocated across loop: %.1f MB -> %.1f MB (delta %+.2f MB)",
                 Double(allocBefore) / mb, Double(allocAfter) / mb, growthMB))
    // RSS is printed for diagnostics only — it moves with the allocator cache
    // described above, so it must not decide the verdict.
    print(String(format: "  RSS (informational): %.1f MB -> %.1f MB (delta %+.1f MB)",
                 Double(rssBefore) / mb, Double(rssAfter) / mb,
                 (Double(rssAfter) - Double(rssBefore)) / mb))
    // Machine-level guard: allocated bytes must not grow with `iters`. A leaked
    // machine is 16 MB, so anything real lands orders of magnitude above this
    // ceiling; observed drift is a few tens of KB. Exact slot-leak detection is
    // the remember/forget balance asserted in Phases 3-5.
    check("no unbounded machine leak (delta < 2 MB)", growthMB < 2)

    phaseResult(1, before)
}

// ---- Phase 2: synchronous host function (JS -> Swift) ----
do {
    let before = failures
    print("PHASE 2 — synchronous host function (JS -> Swift)")

    guard let engine = makeEngine() else {
        check("create machine", false)
        phaseResult(2, before)
        exit(1)
    }

    DemoHost.syncCallCount = 0
    let result = try? engine.eval("host.add(2, 3)")
    check("host.add(2, 3) == 5", result == "5")
    check("Swift host call executed (count == 1)", DemoHost.syncCallCount == 1)

    phaseResult(2, before)
}

// ---- Phase 3: asynchronous bridge (THE critical phase) ----
do {
    let before = failures
    print("PHASE 3 — async bridge (echo)")

    // Test A: load agents/echo.js — `const r = await host.echo("hi"); print(r)`.
    if let engine = makeEngine() {
        let path = "agents/echo.js"
        if let src = try? String(contentsOfFile: path, encoding: .utf8) {
            _ = try? engine.eval(src)
            check("echo kicked off one async call", engine.pendingCount == 1)
            engine.runUntilIdle()
            check("echo.js printed \"hi\"", engine.outputs == ["hi"])
            check("all async calls settled", engine.pendingCount == 0)
        } else {
            check("read \(path)", false)
        }
    } else {
        check("create machine", false)
    }

    // Test B: 100 sequential echoes — all correct, no leak.
    if let engine = makeEngine() {
        let n = 100
        let agent = """
        (async () => {
          for (let i = 0; i < \(n); i++) {
            const r = await host.echo("n" + i);
            print(r);
          }
        })();
        """
        _ = try? engine.eval(agent)
        engine.runUntilIdle(timeout: 30)

        let out = engine.outputs
        check("\(n) sequential echoes all printed", out.count == n)
        let allCorrect = out.enumerated().allSatisfy { $0.element == "n\($0.offset)" }
        check("\(n) echoes all correct and in order", allCorrect)
        check("id table empty at end", engine.pendingCount == 0)
        let (remembered, forgotten) = engine.rememberForgetCounts
        check("remember/forget balanced (\(remembered) == \(forgotten))", remembered == forgotten)
        check("rooted exactly 2 slots per call (\(remembered) == \(2 * n))", remembered == UInt32(2 * n))
    } else {
        check("create machine", false)
    }

    phaseResult(3, before)
}

// ---- Phase 4: streaming via reverse channel ----
do {
    let before = failures
    print("PHASE 4 — streaming (reverse channel)")

    if let engine = makeEngine() {
        let path = "agents/stream.js"
        if let src = try? String(contentsOfFile: path, encoding: .utf8) {
            _ = try? engine.eval(src)
            let start = Date()
            engine.runUntilIdle()
            let elapsed = Date().timeIntervalSince(start)

            let out = engine.outputs
            let expected = ["delta:Hello", "delta: ", "delta:from", "delta: ",
                            "delta:Swift", "full:Hello from Swift"]
            check("5 deltas then final, in order", out == expected)
            let deltas = out.filter { $0.hasPrefix("delta:") }
            check("received 5 deltas", deltas.count == 5)
            // Tokens are 50 ms apart: a single block would finish near-instantly.
            check("tokens arrived incrementally (elapsed \(String(format: "%.2f", elapsed))s ≥ 0.2s)",
                  elapsed >= 0.2)
            check("all settled", engine.pendingCount == 0)
            let (remembered, forgotten) = engine.rememberForgetCounts
            check("remember/forget balanced (\(remembered) == \(forgotten))", remembered == forgotten)
            check("rooted 3 slots (resolve+reject+onToken) (\(remembered) == 3)", remembered == 3)
        } else {
            check("read \(path)", false)
        }
    } else {
        check("create machine", false)
    }

    phaseResult(4, before)
}

// ---- Phase 5: concurrency & robustness ----
do {
    let before = failures
    print("PHASE 5 — concurrency & robustness")

    func loadAgent(_ name: String) -> String? {
        try? String(contentsOfFile: "agents/\(name)", encoding: .utf8)
    }

    func balanced(_ engine: XSEngine) -> Bool {
        let (r, f) = engine.rememberForgetCounts
        return r == f && engine.pendingCount == 0
    }

    // Concurrent: Promise.all of several in-flight echoes, no id crosstalk.
    if let engine = makeEngine(), let src = loadAgent("concurrent.js") {
        _ = try? engine.eval(src)
        engine.runUntilIdle()
        check("concurrent Promise.all preserves results", engine.outputs == ["all:a,b,c,d"])
        check("concurrent: roots balanced, table empty", balanced(engine))
    } else {
        check("concurrent.js", false)
    }

    // Reject path: host.fail() -> Swift reject -> JS catch, no escape to Swift.
    if let engine = makeEngine(), let src = loadAgent("error.js") {
        _ = try? engine.eval(src)
        engine.runUntilIdle()
        check("reject surfaces in JS catch", engine.outputs == ["caught:deliberate failure"])
        check("reject: roots balanced, table empty", balanced(engine))
    } else {
        check("error.js", false)
    }

    // Mixed sequential agent: echo then stream, distinct ids, no crosstalk.
    if let engine = makeEngine(), let src = loadAgent("sequential.js") {
        _ = try? engine.eval(src)
        engine.runUntilIdle()
        let expected = ["echo:first", "delta:Hello", "delta: ", "delta:from",
                        "delta: ", "delta:Swift", "stream:Hello from Swift"]
        check("mixed echo+stream agent in order", engine.outputs == expected)
        check("mixed: roots balanced, table empty", balanced(engine))
    } else {
        check("sequential.js", false)
    }

    // Stress: >= 5000 calls, batches in flight, forced GC between turns.
    if let engine = makeEngine() {
        let batches = 100, perBatch = 50  // 5000 calls
        let agent = """
        (async () => {
          let ok = 0, bad = 0;
          for (let b = 0; b < \(batches); b++) {
            const ps = [];
            for (let i = 0; i < \(perBatch); i++) {
              const v = "v" + b + "_" + i;
              ps.push(host.echo(v).then(r => { r === v ? ok++ : bad++; }));
            }
            await Promise.all(ps);
          }
          print("stress ok:" + ok + " bad:" + bad);
        })();
        """
        let rssBefore = residentBytes()
        _ = try? engine.eval(agent)
        engine.runUntilIdleForcingGC()
        let rssAfter = residentBytes()

        let total = batches * perBatch
        check("stress: \(total) calls all correct, none mixed up",
              engine.outputs == ["stress ok:\(total) bad:0"])
        check("stress: id table empty", engine.pendingCount == 0)
        let (remembered, forgotten) = engine.rememberForgetCounts
        check("stress: remember/forget balanced (\(remembered) == \(forgotten))",
              remembered == forgotten)
        check("stress: rooted 2 per call (\(remembered) == \(2 * total))",
              remembered == UInt32(2 * total))
        let growthMB = (Double(rssAfter) - Double(rssBefore)) / 1_048_576
        print(String(format: "  stress RSS: %.1f MB -> %.1f MB (delta %+.1f MB)",
                     Double(rssBefore) / 1_048_576, Double(rssAfter) / 1_048_576, growthMB))
        check("stress: memory stable (delta < 20 MB)", growthMB < 20)
    } else {
        check("create machine", false)
    }

    phaseResult(5, before)
}

// ---- Phase 6: ES module loader (custom fxFindModule / fxLoadModule) ----
do {
    let before = failures
    print("PHASE 6 — ES module loader")

    if let engine = makeEngine() {
        // Dynamic import resolves through the filesystem loader (cwd-relative,
        // explicit extension); the imported module itself uses a static
        // `import ... from './…'` (module goal, importer-relative), so a green
        // here proves both the loader wiring and module-goal parsing.
        _ = try? engine.eval("""
            globalThis.__m = 'pending';
            import('agents/modules/reexport.js')
              .then(function (m) { globalThis.__m = 'ok:' + m.doubled; })
              .catch(function (e) { globalThis.__m = 'err:' + String(e); });
            """)
        engine.runUntilIdle()
        let r = (try? engine.eval("globalThis.__m")) ?? "<none>"
        check("dynamic import + static re-export == 84 (got \(r))", r == "\"ok:84\"")

        // A missing module rejects cleanly — no crash, catchable in JS.
        _ = try? engine.eval("""
            globalThis.__n = 'pending';
            import('ghost').then(function () { globalThis.__n = 'resolved'; })
                           .catch(function () { globalThis.__n = 'rejected'; });
            """)
        engine.runUntilIdle()
        let r2 = (try? engine.eval("globalThis.__n")) ?? "<none>"
        check("missing module rejects (got \(r2))", r2 == "\"rejected\"")
    } else {
        check("create machine", false)
    }

    phaseResult(6, before)
}

// PHASE 7: JS-initiated thread spawn + GC teardown (the Thread primitive). A
// script creates child engines with `new Thread(...)`; unreferenced, they are
// collected and their host destructor tears the child engine down — everything
// initiated from JS, machine lifecycle owned by Swift's factory.
do {
    let before = failures
    print("PHASE 7: JS Thread spawn + teardown")
    DemoThreads.resetCounters()
    if let engine = makeEngine() {
        engine.withMachine { xsThreadInstall($0) }
        _ = try? engine.eval("(function () { new Thread('w1'); new Thread('w2'); })(); 0")
        check("2 child engines spawned (\(DemoThreads.createdCount))",
              DemoThreads.createdCount == 2)
        // The Thread objects are unreferenced; a full GC finalizes them, and
        // each host destructor tears its child engine down.
        engine.withMachine { xsBridgeCollectGarbage($0) }
        engine.withMachine { xsBridgeCollectGarbage($0) }
        check("both child engines torn down after GC (\(DemoThreads.destroyedCount))",
              DemoThreads.destroyedCount == 2)
    } else {
        check("create engine", false)
    }
    phaseResult(7, before)
}

// PHASE 8: JS-initiated Service round-trip. A supervisor script spawns a child
// engine (`new Thread`), binds a `Service` to a module, and `await`s methods on
// it — args and result cross as alien-marshalled values; the child imports the
// module and runs its default export. Everything is initiated from the script.
do {
    let before = failures
    print("PHASE 8: JS Thread + Service round-trip")
    // Source = a module (imported by the child via an absolute specifier).
    let moduleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("xsb-service-\(getpid()).mjs")
    let moduleSrc = """
    export default {
        double({ n }) { return { doubled: n * 2 }; },
        greet({ who }) { return new Promise(function (r) { r({ hello: who }); }); }
    };
    """
    try? moduleSrc.write(to: moduleURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: moduleURL) }

    if let engine = makeEngine() {
        engine.withMachine { xsThreadInstall($0) }
        // A relative module specifier resolves against globalThis.__moduleBase.
        let script = """
        globalThis.__moduleBase = '\(moduleURL.deletingLastPathComponent().path)';
        globalThis.__r = 'pending';
        (async function () {
            const t = new Thread('worker');
            const svc = new Service(t, './\(moduleURL.lastPathComponent)');
            const a = await svc.double({ n: 21 });   // sync handler
            const b = await svc.greet({ who: 'tykaoz' });  // Promise handler
            globalThis.__r = { a: a, b: b };
        })().catch(function (e) { globalThis.__r = { error: String((e && e.stack) || e) }; });
        """
        _ = try? engine.eval(script)
        engine.runUntilIdle(timeout: 5)
        let got = (try? engine.eval("globalThis.__r")) ?? "<none>"
        check("service round-trip via Thread+Service (got \(got))",
              got.contains("\"doubled\":42") && got.contains("\"hello\":\"tykaoz\""))
        // Invariant #4: the client rooted resolve/reject per call and forgot them
        // at settle — balanced, and no call left pending.
        engine.withMachine { m in
            var remembered: UInt32 = 0, forgotten: UInt32 = 0
            xsBridgeDebugCounts(m, &remembered, &forgotten)
            check("client roots balanced (\(remembered) == \(forgotten))", remembered == forgotten)
            check("client idle (pending == 0)", xsBridgePendingCount(m) == 0)
        }
    } else {
        check("create engine", false)
    }
    phaseResult(8, before)
}

// PHASE 9: module roots (Moddable-style). A registered root resolves bare
// specifiers (no `./`, no extension — `.xsb`/`.mjs`/`.js` searched), a named
// prefix maps to an external directory, and resolution is confined to the roots.
do {
    let before = failures
    print("PHASE 9: module roots (bare specifiers + confinement)")
    let fm = FileManager.default
    let baseDir = fm.temporaryDirectory.appendingPathComponent("xsb-roots-\(getpid())")
    let root = baseDir.appendingPathComponent("root")
    let sub = root.appendingPathComponent("sub")
    let lib = baseDir.appendingPathComponent("lib")
    let trusted = baseDir.appendingPathComponent("trusted")
    try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
    try? fm.createDirectory(at: lib, withIntermediateDirectories: true)
    try? fm.createDirectory(at: trusted, withIntermediateDirectories: true)
    // greeter (bare, extension-less), sub/util (subdir), lib/tool (named root),
    // a secret OUTSIDE every root/prefix (a `..` escape AND a bare absolute path
    // must be blocked), and a trusted/bundle simulating a framework resource
    // loaded by absolute path (must resolve despite confinement).
    try? "export default \"hi from greeter\";".write(
        to: root.appendingPathComponent("greeter.mjs"), atomically: true, encoding: .utf8)
    try? "export default 7;".write(
        to: sub.appendingPathComponent("util.mjs"), atomically: true, encoding: .utf8)
    try? "export default \"lib tool\";".write(
        to: lib.appendingPathComponent("tool.mjs"), atomically: true, encoding: .utf8)
    try? "export default \"LEAKED\";".write(
        to: baseDir.appendingPathComponent("secret.mjs"), atomically: true, encoding: .utf8)
    // bundle.mjs re-exports via a RELATIVE import of a sibling — the provider's
    // real pattern (its modules import each other by `./x`), which must resolve
    // inside a trusted prefix even while an agent's roots confine the loader.
    try? "import v from \"./helper.mjs\"; export default v;".write(
        to: trusted.appendingPathComponent("bundle.mjs"), atomically: true, encoding: .utf8)
    try? "export default \"TRUSTED OK\";".write(
        to: trusted.appendingPathComponent("helper.mjs"), atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: baseDir) }

    if let engine = makeEngine() {
        engine.withMachine { _ in
            xsBridgeAddModuleRoot("", root.path)
            xsBridgeAddModuleRoot("lib", lib.path)
            xsBridgeAddTrustedModulePrefix(trusted.path)   // framework bundle dir
        }
        // An arbitrary absolute path (outside every root/prefix) is BLOCKED —
        // an agent can't escape via `/abs`. An absolute path inside a trusted
        // prefix RESOLVES — the framework's bundle-import case.
        let absSecret = baseDir.appendingPathComponent("secret.mjs").path
        let absTrusted = trusted.appendingPathComponent("bundle.mjs").path
        _ = try? engine.eval("""
            globalThis.__r = {};
            Promise.all([
                import("greeter").then(function (m) { __r.bare = m.default; }),
                import("sub/util").then(function (m) { __r.subdir = m.default; }),
                import("lib/tool").then(function (m) { __r.named = m.default; }),
                import("lib/../../secret")
                    .then(function (m) { __r.escape = "LOADED:" + m.default; })
                    .catch(function () { __r.escape = "blocked"; }),
                import("\(absSecret)")
                    .then(function (m) { __r.abs = "LEAKED:" + m.default; })
                    .catch(function () { __r.abs = "blocked"; }),
                import("\(absTrusted)")
                    .then(function (m) { __r.trusted = m.default; })
                    .catch(function () { __r.trusted = "blocked"; }),
            ]).catch(function () {});
            """)
        engine.runUntilIdle(timeout: 5)
        let got = (try? engine.eval("globalThis.__r")) ?? "<none>"
        check("bare specifier resolves (.mjs) — \(got)", got.contains("\"bare\":\"hi from greeter\""))
        check("bare subdir resolves", got.contains("\"subdir\":7"))
        check("named root prefix resolves", got.contains("\"named\":\"lib tool\""))
        check("`..` escape is confined (blocked)", got.contains("\"escape\":\"blocked\""))
        check("arbitrary absolute path is blocked", got.contains("\"abs\":\"blocked\""))
        check("trusted-prefix absolute path resolves", got.contains("\"trusted\":\"TRUSTED OK\""))
        engine.withMachine { _ in
            xsBridgeClearModuleRoots()
            xsBridgeClearTrustedModulePrefixes()
        }
    } else {
        check("create engine", false)
    }
    phaseResult(9, before)
}

// PHASE 10: calling a named module export from Swift (XSEngine.callModule) —
// the mechanism that lets the bridge drive JS without naming a global function.
// The load-bearing assertion is RE-ENTRANCY: two calls in flight with different
// payloads must each see their own, which is why the payload is captured into a
// closure before the import resolves rather than read off `__xsbInput` later.
do {
    let before = failures
    print("PHASE 10: named module export calls (XSEngine.callModule)")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("xsb-modcall-\(getpid())")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

    // Module-scope state, so we also prove the module cache keeps it across calls
    // (a stateful orchestrator depends on that).
    let source = """
    globalThis.__seen = [];
    let calls = 0;
    export function plain(p) { calls += 1; globalThis.__seen.push(p.tag); return p.tag; }
    export function counted() { return calls; }
    export function viaHost(p) {
        return host.echo(p.tag).then(function (r) { globalThis.__seen.push("host:" + r); });
    }
    export function boom() { throw new Error("boom from module"); }
    export const notAFunction = 42;
    """
    let modulePath = dir.appendingPathComponent("svc.mjs").path
    try? source.write(to: URL(fileURLWithPath: modulePath), atomically: true, encoding: .utf8)

    if let engine = makeEngine() {
        // Predicates are evaluated in JS: `eval` returns JSON, so substring
        // matching on a stringified array fights the escaping instead of the
        // behaviour.
        func sawTag(_ engine: XSEngine, _ tag: String) -> Bool {
            ((try? engine.eval("globalThis.__seen.indexOf(\"\(tag)\") >= 0")) ?? "false") == "true"
        }

        // 1. A plain export receives its parsed payload.
        _ = try? engine.callModule(modulePath, export: "plain", params: #"{"tag":"one"}"#)
        engine.runUntilIdle(timeout: 5)
        check("plain export sees its payload", sawTag(engine, "one"))

        // 2. Two calls in flight with different payloads: neither may see the
        //    other's. A shared per-machine param slot would fail this.
        _ = try? engine.callModule(modulePath, export: "plain", params: #"{"tag":"A"}"#)
        _ = try? engine.callModule(modulePath, export: "plain", params: #"{"tag":"B"}"#)
        engine.runUntilIdle(timeout: 5)
        check("overlapping calls keep distinct payloads",
              sawTag(engine, "A") && sawTag(engine, "B"))

        // 3. Module-scope state survives across calls (module cache hit).
        _ = try? engine.callModule(modulePath, export: "counted", params: "null")
        engine.runUntilIdle(timeout: 5)
        let counted = (try? engine.eval("globalThis.__seen.length")) ?? "0"
        check("module-scope state persists across calls (3 payloads seen) — \(counted)",
              counted == "3")

        // 4. An export whose promise is settled by a Swift host call.
        _ = try? engine.callModule(modulePath, export: "viaHost", params: #"{"tag":"echo-me"}"#)
        engine.runUntilIdle(timeout: 5)
        check("export awaiting a host call completes", sawTag(engine, "host:echo-me"))

        // 5. A throwing export must not corrupt the engine: the next call still works.
        _ = try? engine.callModule(modulePath, export: "boom", params: "null")
        engine.runUntilIdle(timeout: 5)
        _ = try? engine.callModule(modulePath, export: "plain", params: #"{"tag":"after-throw"}"#)
        engine.runUntilIdle(timeout: 5)
        check("engine survives a throwing export", sawTag(engine, "after-throw"))

        // 6. KNOWN GAP, asserted as-is rather than papered over: a missing or
        //    non-callable export rejects *asynchronously* (the lookup happens in
        //    the import's `then`), so `callModule` cannot report it and the caller
        //    sees silence. Harmless for the agent layer, whose outcomes travel
        //    through host.__report / __deliverResult, but a framework typo would
        //    hang until the delivery timeout. Stage 2 closes this when it rederives
        //    error surfacing; this assertion documents today's behaviour so the fix
        //    is visible as a change.
        var threwSynchronously = false
        do { _ = try engine.callModule(modulePath, export: "notAFunction", params: "null") }
        catch { threwSynchronously = true }
        engine.runUntilIdle(timeout: 5)
        check("non-callable export rejects asynchronously, not synchronously (known gap)",
              !threwSynchronously)
        check("engine still usable after a non-callable export",
              { _ = try? engine.callModule(modulePath, export: "plain", params: #"{"tag":"after-bad-export"}"#)
                engine.runUntilIdle(timeout: 5)
                return sawTag(engine, "after-bad-export") }())

        // 7. Invariant 4: every remembered slot forgotten, nothing left in flight.
        engine.runUntilIdle(timeout: 5)
        var remembered: UInt32 = 0
        var forgotten: UInt32 = 0
        engine.withMachine { xsBridgeDebugCounts($0, &remembered, &forgotten) }
        check("roots balanced (\(remembered) == \(forgotten))", remembered == forgotten)
        check("idle (pending == 0)", engine.pendingCount == 0)
    } else {
        check("create engine", false)
    }
    phaseResult(10, before)
}

exit(failures == 0 ? 0 : 1)
