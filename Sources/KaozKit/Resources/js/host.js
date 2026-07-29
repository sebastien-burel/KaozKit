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

// --- LLM providers ----------------------------------------------------------
// A provider handle: `provider("mlx", { model }).chat(messages, { tools }, onToken)`.
// `id` selects the provider (omit for the run's default); extra options (model,
// baseURL, …) go to the host's Swift resolver. Secrets stay in Swift — never
// pass an API key from here.
//
// NOTE: agent-orchestrator.js still assigns its own copy onto `host.provider`
// for agents that use the global. That duplication is deliberate for this step
// and disappears when the orchestrator itself imports from this module.

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

/// The provider ids and names the host exposes, for discovery from JS.
export function providers() { return globalThis.__providerCatalog || []; }
