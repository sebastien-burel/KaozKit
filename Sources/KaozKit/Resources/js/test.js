// A test harness for agents, in the XS subset — assertions plus a suite runner.
//
// It ships with the host so that any kaoz agent can test itself with no module
// mounting at all: `kaoz` registers this bundle under the `kaoz` prefix, the
// same way `kaoz/host` resolves. Nothing here knows anything about actors, or
// about any particular framework.
//
// Reporting rides on the two channels the CLI already gives an agent:
//   host.log  → stderr, prefixed "[log]"  (progress, one line per failure)
//   run()'s return value → stdout as JSON (the machine-readable report)
// A failing suite THROWS, which is what makes kaoz exit non-zero. Nothing
// downstream has to parse anything.

// Relative, NOT the bare "kaoz/host" an agent would write: bundled modules
// import each other by path inside the trusted prefix, as the orchestrator does.
import { log } from "./host.js";

// --- Assertions --------------------------------------------------------------

export class AssertionError extends Error {
  constructor(message) {
    super(message);
    this.name = "AssertionError";
  }
}

// JSON.stringify returns undefined for functions and undefined itself; fall
// back to String so a message never reads "expected undefined" by accident.
function show(value) {
  const json = JSON.stringify(value);
  return json === undefined ? String(value) : json;
}

function fail(message, detail) {
  throw new AssertionError(message ? message + " — " + detail : detail);
}

/// Identity (===). For data structures, use deepEqual.
export function equal(actual, expected, message) {
  if (actual !== expected) {
    fail(message, "expected " + show(expected) + ", got " + show(actual));
  }
}

/// Structural equality over plain data (primitives, arrays, plain objects).
/// Not for class instances.
export function deepEqual(actual, expected, message) {
  if (!same(actual, expected)) {
    fail(message, "expected " + show(expected) + ", got " + show(actual));
  }
}

function same(a, b) {
  if (a === b) return true;
  if (a === null || b === null) return false;
  if (typeof a !== "object" || typeof b !== "object") return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const keys = Object.keys(a);
  if (keys.length !== Object.keys(b).length) return false;
  for (const key of keys) {
    if (!same(a[key], b[key])) return false;
  }
  return true;
}

/// Asserts fn throws; returns the error so the caller can inspect it.
export function throws(fn, message) {
  try {
    fn();
  } catch (error) {
    return error;
  }
  fail(message, "no exception thrown");
}

/// Asserts the promise rejects; resolves with the rejection reason.
export async function rejects(promise, message) {
  try {
    await promise;
  } catch (error) {
    return error;
  }
  fail(message, "the promise resolved instead of rejecting");
}

// --- The runner --------------------------------------------------------------

/// suites: [{ name, module }] — every exported function of a module whose name
/// does not start with "_" is a test. A test fails by throwing.
///
/// options.afterEach: called after each test; anything it returns fails that
/// test, even though nothing threw into it. That is how a framework surfaces a
/// violation its own guards caught outside any handler — the runner stays
/// ignorant of what is being guarded.
export async function runSuites(suites, options) {
  const afterEach = (options && options.afterEach) || null;
  const report = { passed: 0, failed: 0, failures: [] };

  for (const suite of suites) {
    let passed = 0;
    let failed = 0;
    for (const name of Object.keys(suite.module)) {
      const test = suite.module[name];
      if (typeof test !== "function" || name.charAt(0) === "_") continue;
      let error = null;
      try {
        // Promise.resolve: a test may await something, or be plain synchronous.
        await Promise.resolve(test());
      } catch (caught) {
        error = caught;
      }
      const leaked = afterEach ? afterEach() : [];
      if (!error && leaked && leaked.length > 0) error = new Error(leaked.join(" | "));
      if (error) {
        failed++;
        const message = String((error && error.stack) || error);
        report.failures.push({ suite: suite.name, test: name, message });
        log("FAIL " + suite.name + " > " + name + ": " + message);
      } else {
        passed++;
      }
    }
    log(suite.name + ": " + passed + " passed, " + failed + " failed");
    report.passed += passed;
    report.failed += failed;
  }

  // A suite that exports nothing runnable would otherwise report a silent green.
  if (report.passed + report.failed === 0) {
    throw new Error("no test ran — the suites export no function");
  }
  if (report.failed > 0) {
    throw new Error(report.failed + " test(s) failed (details above)");
  }
  return report;
}
