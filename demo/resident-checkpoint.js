// A resident agent that checkpoints its own state and survives a hard kill.
//
//   kaoz demo/resident-checkpoint.js --resident --daemon \
//        --state /tmp/counter.snap --input arm
//
// Ctrl-C is not the interesting case (the CLI already snapshots on a signal).
// `kill -9` it: the count comes back, because every tick asks for a checkpoint.

import { log, every, cancel, snapshot, restored } from "kaoz/host";

let ticks = 0;
let handle = 0;

// Re-armable from state alone — no timer handle is ever persisted, because a
// handle names a Swift-side timer that dies with the process.
function arm() {
  if (handle) cancel(handle);
  handle = every(2000, { from: "resident-checkpoint" });
  return handle;
}

export default {
  onMessage(m) {
    if (m === "status") return { ticks, handle, restored: restored() };
    return { armed: arm() };
  },

  onTick() {
    ticks++;
    // A request, not a write: the host takes it once this delivery has settled.
    const accepted = snapshot("tick " + ticks);
    return { ticks, checkpointing: accepted };
  },

  // Delivered once by the host after reviving a snapshotted heap. `ticks` is
  // already back — it lived in the heap. The timer did not.
  onRestore(info) {
    log("restored", JSON.stringify(info), "at tick", String(ticks));
    return { rearmed: arm(), ticks };
  },
};
