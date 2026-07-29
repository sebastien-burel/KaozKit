// Loads JS-authored tool modules for a JSToolBundle engine.
//
// Replaces a Swift-generated bootstrap script that was eval'd and whose specs
// were read back from the eval's return value. Swift now calls `init` and reads
// the specs from a probe global, because a module call cannot return a promise's
// value.
//
// `globalThis.tools` and `globalThis.__toolConfig` stay globals on purpose: both
// are documented public contracts of JSToolBundle — a consumer may supply its own
// script that declares `globalThis.tools`, and the bundled tools read their
// configuration (API keys) from `__toolConfig`.

/// Import each module path and register its default export as a tool.
///
/// `globalThis.__kaozToolSpecs` receives the JSON specs once every module has
/// loaded; it is `null` until then and on failure, which is how Swift tells
/// "not ready" from "no tools".
export function init(params) {
  const { modules, config } = params;
  globalThis.__kaozToolSpecs = null;
  if (config) globalThis.__toolConfig = config;
  if (!Array.isArray(globalThis.tools)) globalThis.tools = [];

  return Promise.all((modules || []).map((p) => import(p)))
    .then((mods) => {
      for (const m of mods) {
        const t = m && m.default;
        if (t && t.name) globalThis.tools.push(t);
      }
      globalThis.__kaozToolSpecs = JSON.stringify(
        globalThis.tools.map((t) => ({
          name: t.name,
          description: t.description,
          input_schema: t.input_schema,
        })));
    })
    .catch(() => { globalThis.__kaozToolSpecs = null; });
}

/// Invoke a registered tool and report the outcome by callId. Lives here rather
/// than in the agent orchestrator because the registry does.
export function callTool(params) {
  const { name, args, callId } = params;
  const tool = (globalThis.tools || []).find((t) => t.name === name);
  if (!tool || typeof tool.run !== "function") {
    host.__toolResult(callId, null, "unknown tool: " + name);
    return;
  }
  Promise.resolve()
    .then(() => tool.run(args))
    .then((r) => { host.__toolResult(callId, JSON.stringify(r === undefined ? null : r), null); })
    .catch((e) => { host.__toolResult(callId, null, String((e && e.stack) || e)); });
}
