// The agent runtime orchestrator. A real ES module: Swift reaches these
// functions through the module namespace (XSEngine.callModule) instead of
// evaluating a global name.
//
// State lives in module scope. Repeated calls hit the module cache, so the same
// instance — and the same loaded agent — is reused; that is what makes a
// resident agent possible.
//
// The `host` object itself is a global, installed from C before any module can
// evaluate. `kaoz/host` is the only module that reads it.

// Relative, NOT the bare "kaoz/host" an agent would write: this module is
// imported by absolute bundle path before any root is registered, and the roots
// are cleared between runs. A relative specifier inside the trusted bundle
// prefix is immune to both.
import { llm, provider, providers, __configure } from "./host.js";

let agent = null;
let agentReady = null;

/// Configure the run. Replaces the `globalThis.__providerCatalog = …` and
/// `globalThis.__moduleBase = …` evals Swift used to issue separately.
export function init(config) {
  __configure(config || {});
  return true;
}

/// One-shot: import the agent module and settle the run with its result.
/// `run` (named) wins over `default`; a bare `globalThis.run` is the last resort.
export function runAgent(params) {
  const { path, input } = params;
  import(path)
    .then((ns) => {
      const run = (ns && (ns.run || ns.default)) || globalThis.run;
      if (typeof run !== "function") throw new Error("l'agent ne définit pas run(input)");
      return run(input);
    })
    .then((r) => { host.__report(JSON.stringify(r === undefined ? null : r)); })
    .catch((e) => { host.__fail(String((e && e.stack) || e)); });
}

/// Resident: import the agent module once and keep it. The default export may be
/// an object of handlers ({ onMessage, onEvent, onTick }) or a plain
/// run(input)/default function (legacy one-shot, treated as onMessage).
export function loadAgent(params) {
  agentReady = import(params.path).then((m) => { agent = (m && (m.default || m)) || {}; });
  return true;
}

/// Deliver one event and settle that delivery by id — WITHOUT ending the run.
export function deliver(params) {
  const { kind, deliveryId, input } = params;
  Promise.resolve(agentReady)
    .then(() => {
      const a = agent || {};
      let fn;
      if (kind === "message") fn = typeof a === "function" ? a : a.onMessage || a.run;
      else if (kind === "event") fn = a.onEvent;
      else if (kind === "tick") fn = a.onTick;
      if (typeof fn !== "function")
        throw new Error("l'agent n'a pas de handler pour '" + kind + "'");
      return fn.call(a, input);
    })
    .then((r) => {
      host.__deliverResult(deliveryId, JSON.stringify(r === undefined ? null : r), false);
    })
    .catch((e) => {
      host.__deliverResult(deliveryId, String((e && e.stack) || e), true);
    });
}

/// Invoke a JS-authored tool from `globalThis.tools` and report by callId.
export function callTool(params) {
  const { name, args, callId } = params;
  const list = globalThis.tools || [];
  const tool = list.find((t) => t.name === name);
  if (!tool || typeof tool.run !== "function") {
    host.__toolResult(callId, null, "unknown tool: " + name);
    return;
  }
  Promise.resolve()
    .then(() => tool.run(args))
    .then((r) => { host.__toolResult(callId, JSON.stringify(r === undefined ? null : r), null); })
    .catch((e) => { host.__toolResult(callId, null, String((e && e.stack) || e)); });
}

// --- Back-compatibility -----------------------------------------------------
// Agents written against the ambient surface keep working: `host.llm`,
// `host.provider`, `host.providers` are re-exposed from kaoz/host (one
// implementation, not a copy), and the old global entry points still exist for
// anything that calls them — including a heap restored from a snapshot taken
// before this module had exports. Remove a release after the last such snapshot
// is gone.
host.provider = provider;
host.llm = llm;
host.providers = providers;

globalThis.__runAgent = (path, inputJSON) => runAgent({ path, input: JSON.parse(inputJSON) });
globalThis.__loadAgent = (path) => loadAgent({ path });
globalThis.__deliver = (kind, deliveryId, inputJSON) =>
  deliver({ kind, deliveryId, input: JSON.parse(inputJSON) });
globalThis.__callTool = (name, argsJSON, callId) =>
  callTool({ name, args: JSON.parse(argsJSON), callId });

// Set LAST, so its presence proves the whole module body evaluated: Swift checks
// it right after init and fails engine creation loudly rather than letting a
// broken orchestrator surface later as a delivery that never settles.
//
// Also the snapshot generation marker — a heap restored from a snapshot written
// before this module had exports has no such global, which is how AgentHost
// knows to keep driving it the old way. A global on purpose: a restored heap can
// only be probed that way.
globalThis.__kaozOrchestrator = 2;
