import { readFile } from "node:fs/promises";
import { launchHelper } from "./launch.mjs";
import { inventoryFile, stateDir } from "./state-dir.mjs";

// Strict-offline restart: the helper forces network emulation off for this process, so every model byte must come
// from the persistent cache written by setup. A changed cache, a missing asset or a dead brain probe stops here.
const helper = await launchHelper({ timeoutMs: 900_000 });
const ready = helper.record;
let status = 1;
try {
  if (!ready.port || !ready.probe?.webgpu) throw new Error("offline runtime was not ready");
  const expected = JSON.parse(await readFile(inventoryFile, "utf8").catch(() => {
    throw new Error(`no setup inventory at ${inventoryFile}; run scripts/local-openlive-setup (it reuses the cached models)`);
  }));
  for (const field of ["count", "bytes", "digest"]) {
    if (ready.probe.inventory?.[field] !== expected[field]) throw new Error(`offline model inventory ${field} changed`);
  }
  process.stdout.write(`${JSON.stringify({
    status: "ready-offline", stateDir, brain: ready.brain, brainProbe: ready.brainProbe,
    webgpu: true, adapter: ready.probe.adapter,
    inventory: { count: ready.probe.inventory.count, bytes: ready.probe.inventory.bytes, digest: ready.probe.inventory.digest },
    sttProbeMs: ready.probe.sttProbeMs, ttsProbeMs: ready.probe.ttsProbeMs,
  })}\n`);
} finally {
  status = await helper.finish();
}
if (status !== 0) process.exit(Number(status));
