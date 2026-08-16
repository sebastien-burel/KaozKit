// The agent-facing capability surface, as an importable module:
//
//   import { llm, tool, memory, log } from "kaoz/host";
//
// The native primitives cannot themselves be modules — KaozHostC `xsSet`s them
// on the global at machine-install time, before any module can evaluate, and the
// .xsb reader explicitly refuses host functions. This file is the ONE place that
// reads that global; everything else imports from here.
//
// `host` stays on the global for agents written against it. Nothing here changes
// that; this is an addition, not a replacement.

const native = globalThis.host;

// --- Diagnostics and accounting ---------------------------------------------

export function log(...args) { return native.log(...args); }
export function usage() { return native.usage(); }

// --- Self-scheduling --------------------------------------------------------
// `schedule` fires once, `every` repeats; both return a handle for `cancel`.
// A tick is delivered to the agent's onTick handler.

export function schedule(delayMs, payload) { return native.schedule(delayMs, payload); }
export function every(intervalMs, payload) { return native.every(intervalMs, payload); }
export function cancel(handle) { return native.cancel(handle); }

// --- Checkpoint and restore --------------------------------------------------
// A heap cannot be written while a handler runs — the JS stack is live and the
// engine may have host calls in flight. `snapshot()` is therefore a *request*:
// the host writes as soon as the current delivery has settled. Ask for it at a
// point you would be happy to wake up at.
//
// `native.snapshot` is feature-detected because a heap restored from a snapshot
// keeps the module cache it was frozen with, while its `host` object comes from
// whatever the writing binary installed — an older one has no `snapshot`.

/// Ask the host to checkpoint the heap. Returns false when this host does not
/// persist at all (a one-shot run, or `kaoz` without `--state`).
export function snapshot(reason) {
  return typeof native.snapshot === "function" ? native.snapshot(reason || "") : false;
}

/// `{ count, at }` when this heap came back from a snapshot, else null. Read off
/// the global every time: no module body re-evaluates on restore, so a value
/// captured at import would be forever stale.
export function restored() { return globalThis.__kaozRestore || null; }

/// Outcome of the last checkpoint: `{ ok, bytes, at, error }`, or null if none
/// was taken in this process.
export function lastSnapshot() { return globalThis.__kaozSnapshot || null; }

// --- Tools ------------------------------------------------------------------

export const tool = {
  list() { return native.tool.list(); },
  call(name, args) { return native.tool.call(name, args); },
};

// --- Memory -----------------------------------------------------------------

export const memory = {
  save(key, value) { return native.memory.save(key, value); },
  read(key) { return native.memory.read(key); },
  list() { return native.memory.list(); },
  search(query, limit) { return native.memory.search(query, limit); },
};

// --- Runtime configuration --------------------------------------------------
// Values Swift used to inject with a `globalThis.x = …` eval. They now arrive
// once, through the orchestrator's `init`, and live in this module's scope.

let providerCatalog = [];

/// Framework-internal: called by agent-orchestrator.js on init. Not for agents.
export function __configure(config) {
  // Merges: `init` is called more than once (the engine factory passes the
  // provider catalog, the session adds its module base), and the second call
  // must not blank what the first set.
  if (!config) return;
  if (config.providerCatalog) providerCatalog = config.providerCatalog;
  // `__moduleBase` must stay a global: the socle's `Service` prelude
  // (KaozJSCore/service.c) reads it to absolutize a relative sub-agent
  // specifier, and the socle ships no modules of its own.
  if (config.moduleBase) globalThis.__moduleBase = config.moduleBase;
}

// --- LLM providers ----------------------------------------------------------
// A provider handle: `provider("mlx", { model }).chat(messages, { tools }, onToken)`.
// `id` selects the provider (omit for the run's default); extra options (model,
// baseURL, …) go to the host's Swift resolver. Secrets stay in Swift — never
// pass an API key from here.

export function provider(id, providerOpts) {
  const opts = providerOpts || {};
  return {
    chat(messages, callOpts, onToken) {
      if (typeof callOpts === "function") { onToken = callOpts; callOpts = {}; }
      callOpts = callOpts || {};
      if (typeof onToken !== "function") onToken = function () {};
      const selector = {};
      if (id !== undefined && id !== null) selector.id = id;
      for (const k in opts) selector[k] = opts[k];
      return native.__chat(messages, callOpts.tools || [], selector, onToken);
    },
  };
}

/// The run's configured provider (whatever `--provider` / the app selected).
export const llm = provider();

/// The provider ids and names the host exposes, for discovery from JS. Falls
/// back to the global for a heap restored from a snapshot written before the
/// catalog moved into module scope.
export function providers() {
  return providerCatalog.length ? providerCatalog : (globalThis.__providerCatalog || []);
}
