import { chmod, writeFile } from "node:fs/promises";
import { launchHelper } from "./launch.mjs";
import { inventoryFile } from "./state-dir.mjs";

// One real WebGPU pass over the fp32 speech models: downloads the assets when absent, runs the strict STT and TTS
// probes, and probes the exact brain model. The inventory it writes is the reference `check-runtime.mjs` verifies.
const helper = await launchHelper({ setup: true });
const ready = helper.record;
let status = 1;
try {
  if (!ready.setup) throw new Error("invalid setup readiness record");
  await writeFile(inventoryFile, `${JSON.stringify(ready.probe.inventory, null, 2)}\n`, { mode: 0o600 });
  await chmod(inventoryFile, 0o600);
  process.stdout.write(`${JSON.stringify({
    status: "ready", stateDir: ready.stateDir, webgpu: ready.probe.webgpu, adapter: ready.probe.adapter,
    brain: ready.brain, brainProbe: ready.brainProbe,
    inventory: { count: ready.probe.inventory.count, bytes: ready.probe.inventory.bytes, digest: ready.probe.inventory.digest },
    sttProbeMs: ready.probe.sttProbeMs, ttsProbeMs: ready.probe.ttsProbeMs,
  })}\n`);
} finally {
  status = await helper.finish();
}
if (status !== 0) process.exit(Number(status));
