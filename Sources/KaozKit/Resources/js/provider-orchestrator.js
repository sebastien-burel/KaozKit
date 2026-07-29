// Drives a JS-authored provider and bridges its outcome to Swift through the
// native __emit / __done / __providerError host functions.
//
// A real ES module: Swift calls `init` once to load the provider module, then
// `chat` per request. The provider used to be parked on globalThis.tyProvider by
// a Swift bootstrap eval; it now lives in this module's scope.

let tyProvider = null;

/// Load the provider module (absolute bundle path) and keep its default export.
///
/// The outcome lands on `globalThis.__kaozProviderReady` rather than in the
/// return value: a module call is fire-and-return, so Swift cannot read a
/// promise's result. A probe global is the only channel that lets construction
/// fail loudly here instead of on the first request.
export function init(params) {
  globalThis.__kaozProviderReady = false;
  return import(params.module).then(
    (m) => {
      tyProvider = (m && m.default) || null;
      globalThis.__kaozProviderReady = !!(tyProvider && typeof tyProvider.chat === "function");
    },
    () => { globalThis.__kaozProviderReady = false; });
}

/// Run one chat request. Streams events through __emit, then __done, or reports
/// through __providerError.
export function chat(request) {
  Promise.resolve()
    .then(() => {
      if (!tyProvider || typeof tyProvider.chat !== "function") {
        throw new Error("provider module did not define a callable chat");
      }
      return tyProvider.chat(request, (event) => { __emit(event); });
    })
    .then(() => { __done(); })
    .catch((err) => { __providerError(String((err && err.stack) || err)); });
}

/// Set last: its presence proves the module body evaluated (Swift checks it).
globalThis.__kaozProviderOrchestrator = 1;
