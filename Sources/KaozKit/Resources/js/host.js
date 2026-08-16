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
//
// TWO CALLING CONVENTIONS, and the difference matters:
//
//   schedule(ms, () => …)      the callback is invoked. Nothing else to write.
//   schedule(ms, { … })        a tick carrying that payload is delivered to the
//                              agent's onTick — the original convention, kept
//                              for agents written against it.
//
// The payload form makes arming and handling two separate obligations: whoever
// arms a timer must also make sure the agent has an onTick that routes the
// payload back. Forget it and no timer ever fires, with no error anywhere. The
// callback form removes the second obligation entirely, so it cannot be
// forgotten — that is the whole point of it.
//
// The id → callback table lives here rather than in the caller, because the
// round trip through Swift is JSON: a function cannot be the payload, so
// something must hold it. This module already is "the one place", and it is
// loaded before any agent module.

const pending = new Map();     // tick id → { fn, repeating }
let nextTick = 0;

/// A handle of 0 means the host did not arm anything — `schedule` is inert
/// outside resident mode. Returning it would hand back a timer that silently
/// never fires, which is the failure this file is trying to abolish.
function armed(handle, delayMs) {
  if (handle) return handle;
  throw new Error(
    "aucun timer armé (" + delayMs + " ms) : host.schedule est inerte hors mode "
    + "résident — lancer kaoz avec --resident");
}

function arm(native_fn, delayMs, fnOrPayload, repeating) {
  if (typeof fnOrPayload !== "function") return armed(native_fn(delayMs, fnOrPayload), delayMs);
  const id = ++nextTick;
  // `armed` lève avant qu'on ne garnisse la table : rien à oublier ensuite.
  const handle = armed(native_fn(delayMs, { __kaozTick: id }), delayMs);
  pending.set(id, { fn: fnOrPayload, handle, repeating });
  return handle;
}

export function schedule(delayMs, fnOrPayload) {
  return arm(native.schedule, delayMs, fnOrPayload, false);
}
export function every(intervalMs, fnOrPayload) {
  return arm(native.every, intervalMs, fnOrPayload, true);
}
export function cancel(handle) {
  for (const [id, entry] of pending) {
    if (entry.handle === handle) { pending.delete(id); break; }
  }
  return native.cancel(handle);
}

/// Called by the orchestrator on every tick, BEFORE the agent's onTick.
/// → true when this tick belonged to a callback armed here, and is now spent.
export function __dispatchTick(payload) {
  const id = payload && payload.__kaozTick;
  if (id === undefined) return false;
  const entry = pending.get(id);
  if (!entry) return true;                    // annulé entre-temps : rien à faire
  if (!entry.repeating) pending.delete(id);
  entry.fn();
  return true;
}

/// Called by the orchestrator after a heap is revived. The closures came back
/// with the heap; the Swift timers they belonged to did not. Keeping them would
/// leave callbacks that can never fire, and a table that only grows.
export function __forgetTicks() {
  pending.clear();
}

/// The standard globals XS does not provide, written on top of the callback
/// form above. Installed by the orchestrator before any agent module evaluates.
///
/// Why bother: code that only needs a delay or a log line should not have to
/// know it is running under this host. `setTimeout` and `console` are ordinary
/// JavaScript, so a library can depend on them and stay portable — whereas
/// naming `host.*` ties it to KaozKit forever.
///
/// These are plain closures, not host functions: the heap serialiser keeps them
/// and the `.xsb` reader has nothing to refuse. The timers behind them still do
/// not survive a restore — nothing can change that — so anything that must
/// outlive a snapshot has to re-arm from its own declarative state.
export function __installStandardGlobals(global) {
  const g = global || globalThis;
  if (typeof g.setTimeout !== "function") {
    g.setTimeout = (fn, ms) => schedule(ms || 0, fn);
    g.clearTimeout = (handle) => { if (handle) cancel(handle); };
    g.setInterval = (fn, ms) => every(ms || 0, fn);
    g.clearInterval = (handle) => { if (handle) cancel(handle); };
  }
  if (typeof g.console !== "object" || g.console === null) {
    const write = (...args) => native.log(...args);
    g.console = { log: write, warn: write, error: write, info: write, debug: write };
  }
}

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
