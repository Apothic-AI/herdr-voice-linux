import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { stateDir } from "./state-dir.mjs";

const electron = join("node_modules", ".bin", "electron");

// Electron 43 downloads its binary on first require and declares no install script, so a fresh
// `pnpm install --frozen-lockfile` has no dist/ yet. Fetch it here, once, with a message, instead of letting a
// surprise download happen inside the helper where a failure looks like a startup timeout.
function ensureElectron() {
  if (!existsSync(electron)) {
    throw new Error(`no Electron at ${electron}; run scripts/local-openlive-setup (it installs pnpm-lock.yaml)`);
  }
  const root = join("node_modules", "electron");
  const pathFile = join(root, "path.txt");
  const installed = existsSync(pathFile) && existsSync(join(root, "dist", readFileSync(pathFile, "utf8").trim()));
  if (installed) return;
  process.stderr.write("local OpenLive: downloading the Electron binary for this platform\n");
  const result = spawnSync(process.execPath, [join(root, "install.js")], { stdio: "inherit" });
  if (result.status !== 0) throw new Error("Electron binary download failed; run npx install-electron");
}

// Launch the helper, hand it the boot record on stdin, and resolve on its first readiness line. Rejects when the
// helper exits first: otherwise a startup failure leaves the caller awaiting a child that already died and reports
// an unsettled top-level await instead of the reason.
export async function launchHelper({ setup = false, timeoutMs = 600_000 } = {}) {
  ensureElectron();
  const token = randomBytes(32).toString("base64url");
  const child = spawn(electron, ["dist/main.mjs"], { stdio: ["pipe", "pipe", "pipe"] });
  child.stdin.write(`${JSON.stringify(setup ? { token, stateDir, setup: true } : { token, stateDir })}\n`);

  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr = `${stderr}${chunk}`.slice(-8000);
    process.stderr.write(chunk);
  });

  // One source of truth for the exit status. A separate `once("exit")` in finish() would miss an exit that
  // already happened, which is the normal case in setup mode: the helper quits as soon as it reports ready.
  const exit = new Promise((resolve) => child.once("exit", (code, signal) => resolve({ code, signal })));
  const earlyExit = exit.then(({ code, signal }) => {
    throw new Error(`the helper exited before it was ready (${signal ? `signal ${signal}` : `status ${code}`})${stderrTail(stderr)}`);
  });
  earlyExit.catch(() => {}); // Reported through the race below; keep Node from treating it as unhandled.
  const failedStart = new Promise((_resolve, reject) => {
    child.once("error", (error) => reject(new Error(`could not start Electron: ${error.message}`)));
  });
  failedStart.catch(() => {});

  const ready = readReady(child.stdout, timeoutMs);
  ready.catch(() => {});
  try {
    const record = await Promise.race([ready, earlyExit, failedStart]);
    return { record, token, child, finish: () => finish(child, exit) };
  } catch (error) {
    child.kill("SIGTERM");
    throw error;
  }
}

function stderrTail(stderr) {
  const lines = stderr.split("\n")
    .filter((line) => line.trim() && !/MESA-LOADER|nss_util|crypto\/nss/.test(line));
  const tail = lines.slice(-6).join("\n");
  return tail ? `:\n${tail}` : "";
}

function readReady(stdout, timeoutMs) {
  return new Promise((resolve, reject) => {
    let buffer = "";
    const timer = setTimeout(() => {
      reject(new Error(`the helper did not report ready within ${timeoutMs}ms`));
    }, timeoutMs);
    stdout.on("data", (chunk) => {
      buffer += chunk.toString();
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        newline = buffer.indexOf("\n");
        let record;
        // Electron and NSS write status lines to our stdout on Linux; only the JSON readiness record matters.
        try { record = JSON.parse(line); } catch { continue; }
        if (record?.type !== "ready") continue;
        clearTimeout(timer);
        resolve(record);
        return;
      }
    });
    stdout.once("end", () => { clearTimeout(timer); reject(new Error("the helper closed stdout before it was ready")); });
  });
}

// Close the boot pipe and let the helper exit on its own; a helper that will not exit is a failure, not a hang.
async function finish(child, exit, timeoutMs = 60_000) {
  child.stdin.end();
  const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
  try {
    const { code } = await exit;
    return code ?? 1;
  } finally {
    clearTimeout(timer);
  }
}
