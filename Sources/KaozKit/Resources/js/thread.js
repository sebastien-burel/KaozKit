// Sub-agent spawn, as an importable module:
//
//   import { Thread, Service } from "kaoz/thread";
//   const svc = new Service(new Thread("researcher"), "researcher");
//   const answer = await svc.ask({ question });
//
// `Thread` and `Service` are installed as globals by the socle
// (KaozJSCore/service.c, xsThreadInstall) plus a small JS prelude it evals.
// They cannot be modules: KaozJSCore ships no resources of its own, by design —
// the socle installs no capabilities. This module is the importable face of them.
//
// Only present when the engine was built with threads installed. A snapshot-
// capable resident agent runs with `installThreads: false`, so importing this
// module there gives you undefined bindings rather than a crash — check before
// use if your agent runs both ways.

export const Thread = globalThis.Thread;
export const Service = globalThis.Service;

/// True when this engine can spawn sub-agents at all.
export function available() {
  return typeof globalThis.Thread === "function" && typeof globalThis.Service === "function";
}

/// The directory of the calling module, for an agent that needs to address files
/// next to itself. Prefer `import.meta.uri` directly — this is a convenience for
/// agents that were written against the `__moduleBase` global.
///
/// `__moduleBase` remains set by the runtime because the socle's `Service`
/// prelude reads it to absolutize a relative sub-agent specifier.
export function moduleBase() {
  return globalThis.__moduleBase;
}
