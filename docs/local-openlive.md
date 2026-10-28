# Local OpenLive

Local OpenLive keeps the native Herdr voice loop. It uses one microphone with echo cancellation, the existing
orb and provider switching, the same confirmation provenance, watches and recap, and the Swift `HerdrTools` executor.
A managed Electron child binds an authenticated WebSocket only on `127.0.0.1`. Its hidden sandboxed renderer runs the
pinned OpenLive `models.worker.ts` directly with WebGPU Whisper tiny.en fp32 and Kokoro fp32. Electron has no mic,
speaker or tool privileges. The main process uses OpenLive's pinned `streamProvider` for the configured brain.

## Setup and run

Local mode is a one-time setup from a source checkout. Until it has run, the orb's menu shows
**Local OpenLive (not set up)**, greyed out. Prerequisites are a desktop with WebGPU, Node 22 or later, pnpm 10 or
later, Ollama with `qwen3.5:4b`, and Swift 5.10 or later; [Linux prerequisites](#linux-prerequisites) lists what a
Linux box needs beyond that. `pnpm-lock.yaml` stays exact and is installed with `--frozen-lockfile`. Keep Ollama in
local-only mode (`OLLAMA_NO_CLOUD=1`). Then run:

```bash
./scripts/local-openlive-setup
swift build -c release
export HERDR_VOICE_LOCAL_OPENLIVE_DIR="$PWD/local-openlive"
./scripts/local-openlive-start
```

Setup clones `https://github.com/katipally/openlive.git` at exact commit
`849173cd1c8c17a95d600b17b428c301722bf5df`, installs `pnpm-lock.yaml`, builds only the selected worker and harness
source, and installs `qwen3.5:4b` through Ollama when absent. It runs real fp32 WebGPU STT and TTS probes plus an
exact-model brain probe. The first run downloads the model files. `local-openlive-check` forces the renderer offline
and repeats the inference probes. A missing asset, WebGPU failure, non-finite or silent TTS, Ollama failure, or schema
mismatch stops startup. The runtime has no CPU, cloud, ACP, or reduced-tool fallback.

### Linux prerequisites

The helper is the same on both platforms; only the GPU backend and the display path differ.
`scripts/local-openlive-preflight` checks everything below before anything expensive runs, and both
`local-openlive-setup` and `local-openlive-check` call it.

| Requirement | Why | Check |
|---|---|---|
| Node 22 or later, pnpm 10 or later | Exact `pnpm-lock.yaml` install and the pinned build | `node -v`, `pnpm -v` |
| Ollama answering on `127.0.0.1:11434` | Default keyless loopback brain | `node -e 'fetch("http://127.0.0.1:11434/api/version")'` |
| `qwen3.5:4b` pulled | Setup probes the exact model ID, not a name pattern | `ollama list` |
| A Vulkan driver listing an ICD | Chromium reaches WebGPU only through Vulkan on Linux | `vulkaninfo --summary` |
| X11 or Wayland display | Electron is a windowed process even with the window hidden | `echo $DISPLAY` |
| PipeWire or PulseAudio | Only the live microphone loop; the helper owns no audio device | `pw-cli info 0` |

The helper enables Chromium's Vulkan backend itself (`--enable-features=Vulkan`, in `local-openlive/src/gpu.ts`,
before app readiness) because Swift launches it with a fixed argv. That selects a GPU backend; it is not a fallback.
Without a real adapter startup still fails with `WebGPU adapter unavailable; local mode has no CPU fallback`, and
`--enable-features=Vulkan` is the difference between that error and a working adapter on an NVIDIA, AMD or Intel GPU.
Electron's `--no-sandbox` is deliberately not added: the helper needs Linux unprivileged user namespaces, which is
the default on current distributions.

Ollama in local-only mode as a user service:

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/ollama.service <<'EOF'
[Unit]
Description=Ollama local model server (loopback only, cloud disabled)
After=network.target

[Service]
Type=simple
Environment=OLLAMA_NO_CLOUD=1
Environment=OLLAMA_HOST=127.0.0.1:11434
ExecStart=/usr/local/bin/ollama serve
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOF
systemctl --user enable --now ollama
```

Adjust `ExecStart` to wherever the distro or Homebrew put the binary.

`MESA-LOADER: failed to open dri: …/dri_gbm.so` on stderr is harmless: it comes from Mesa's GBM loader inside the GPU
process, while the adapter is created through Vulkan. The probes report the adapter they actually got, so a real GPU
failure appears as `adapter: null` and a non-zero exit, never as a silent CPU path.

If the Electron child crashes mid-session, herdr-voice relaunches it and reconnects to its new port, with the
conversation recap, in about 5 s on a warm model cache. A helper that keeps failing backs off like any lost connection
(1, 2, 4 … 30 s) and gives up after 8 tries; ⌥⌘M or choosing Local from the orb then tries again.

A dropped **socket** is not a dead **host**, and the difference is worth the warm models. The helper is a long-lived
Electron process that takes several seconds to reload its models, and its loopback port stays valid for as long as it
lives, so the two failures are handled differently:

| Failure | What happens |
|---|---|
| The socket dropped, the helper is alive | Redial the same port: 0.2 s, 0.5 s, then 1 s apart, up to 6 tries. Warm models are kept, nothing is said, and the orb goes back to blue when the session is up |
| The helper process is gone | Relaunch it (SIGTERM, then SIGKILL and a wait for exit if it ignores that), reload the models, and reconnect; two relaunches in a row is the limit, then it stops with one readable line |

Only a host whose process is actually gone is relaunched (`Reconnect.relaunchesHelper`); a live host whose port stopped
answering is retried and then reported, never silently replaced. That is the fix for a reconnect loop that ran in the
window: every late keepalive used to relaunch the whole inference host, so one slow beat became a restart cycle.

The keepalive is a `heartbeat` message the helper answers every 5 s, and the socket is only called dead after **two**
consecutive misses — one slow turn is not evidence of anything. The helper answers from its own socket handler, never
from a turn in flight, so a GPU that is busy transcribing or synthesising cannot make the socket look dead. A
WebSocket ping could not do this job on Linux: swift-corelibs-foundation writes the ping frame but never calls the pong
handler, so a ping-based check reports every live socket as dead.

`scripts/local-keepalive-check` proves all of it against the real helper: it holds a quiet session for the keepalive
window, stalls the helper's heartbeats to show a socket retry with no relaunch, kills the helper to show a relaunch
with the orb red then blue, and checks that neither case leaves an Electron process behind.

This version uses Electron's persistent Cache API for speech assets. The cache, Electron's other data, and the setup
inventory live in a state directory outside the plugin folder, so a plugin update from `herdr plugin install` keeps
them:

| What | Where |
|---|---|
| State directory | `~/.local/state/herdr-voice/local-openlive` |
| Electron data and model cache | `electron/` in the state directory |
| Setup inventory | `model-inventory.json` in the state directory, mode 0600 |

Swift passes the state directory to Electron in the boot JSON over stdin, never argv. The path is fixed, so setup from a
plain terminal, the check script and the plugin pane always use the same directory. Herdr's per-plugin
`HERDR_PLUGIN_STATE_DIR` is deliberately not used.

Setup writes the verified URL, size, and SHA-256 inventory there. Runtime compares the aggregate count, bytes, and
digest with that file. It also performs real inference before it says ready. A missing or different inventory stops
startup and names the directory it checked.

Earlier versions kept the cache in Electron's default `~/Library/Application Support/Electron` and the inventory in
`local-openlive/.local-model-inventory.json`. Run `scripts/local-openlive-setup` once after updating. When the state
directory has no cache yet, the helper copies the old one over first, so setup reuses it and writes the new inventory.
Until then the menu entry stays greyed out. The helper copies instead of moving, so an older checkout keeps working;
delete the old folder when you no longer need it. A legacy inventory still in the runtime folder is copied too.

The OpenLive source and npm dependencies are exactly pinned. The pinned worker selects the model revisions. This
version does not check in an immutable model weight manifest, so do not describe the browser model weights as
revision-pinned.

Useful checks:

```bash
./scripts/local-openlive-check               # types, unit tests, build, strict-offline WebGPU probes
.build/release/herdr-voice local schemas     # read-only exact Swift schema/manifest JSON
./scripts/local-openlive-demo                # public WAV -> Whisper -> Qwen -> Swift list_agents -> Kokoro WAV
./scripts/local-openlive-bench 5             # raw JSONL first-PCM proxy runs and WAV artifacts
```

The demo replays the exact authenticated LocalWire transport without opening a second microphone. It feeds a public
PCM16 WAV generated from the public phrase "List my Herdr agents," lets Swift's exported schemas drive Qwen, and
requires the harmless real Swift `list_agents` call. Raw agent names and output remain in memory and are never printed or committed. The generated WAV and JSONL live
under ignored `bench-results/`.

## Brain settings

The default brain is keyless loopback Ollama at `http://127.0.0.1:11434/v1`, model `qwen3.5:4b`, OpenAI Chat
Completions protocol, and `reasoning_effort: none`. Local mode rejects non-loopback URLs and cloud-named models.

| Variable | Default | Meaning |
|---|---|---|
| `HERDR_VOICE_LOCAL_BRAIN_KIND` | `local` | `local`, `keyed`, or `custom` |
| `HERDR_VOICE_LOCAL_BRAIN_MODEL` | `qwen3.5:4b` | Exact model ID |
| `HERDR_VOICE_LOCAL_BRAIN_URL` | `http://127.0.0.1:11434/v1` | Provider base URL |
| `HERDR_VOICE_LOCAL_BRAIN_PROTOCOL` | `openai-chat` | `openai-chat`, `openai`, or `anthropic` from the pinned harness |
| `HERDR_VOICE_LOCAL_BRAIN_REASONING` | `none` | Raw provider reasoning setting |
| `HERDR_VOICE_LOCAL_BRAIN_LABEL` | | Required visible label for a nonlocal brain; the orb logs `Hybrid: …` |
| `HERDR_VOICE_LOCAL_BRAIN_KEYCHAIN` | `HERDR_LOCAL_BRAIN_API_KEY` | Keychain service for a keyed brain |

The key moves from Keychain to Electron over the private boot pipe. It never appears in argv, URLs, stdout or logs.
`keyed` requires a key in that service; `custom` may be keyless. Remote brains are intentional hybrid mode: speech
stays local, text goes to that named provider.

## Voice examples for every tool

These all use the original Swift dispatcher. With `HERDR_VOICE_SHELL=1`, the final two raise the count from 30 to 32.

| Swift tool | Example to say |
|---|---|
| `list_agents` | "What agents are running?" |
| `prompt_agent` | "Tell claude-2 to run the tests." |
| `read_agent` | "What is codex doing?" |
| `answer_agent` | "Approve that agent prompt." |
| `focus` | "Show me the forge workspace." |
| `close_workspace` | "Close the scratch workspace." |
| `close_tab` | "Close the notes tab." |
| `remove_worktree` | "Remove the finished login worktree." |
| `list_workspaces` | "List my workspaces." |
| `create_workspace` | "Create an API workspace in my dev folder." |
| `rename_workspace` | "Rename forge-old to archive." |
| `create_tab` | "Add a logs tab to forge." |
| `rename_tab` | "Rename this tab to scratch." |
| `list_worktrees` | "What worktrees does forge have?" |
| `create_worktree` | "Create a worktree on a patch branch for login." |
| `open_worktree` | "Open the existing login-fix worktree." |
| `start_agent` | "Start Codex in a new tab and have it review the API." |
| `list_panes` | "What panes are in this workspace?" |
| `read_pane` | "Read the build pane." |
| `watch_pane` | "Tell me when the build prints done." |
| `split_pane` | "Split the server pane down." |
| `close_pane` | "Close the scratch pane." |
| `zoom_pane` | "Zoom the dev server." |
| `resize_pane` | "Make claude-2 wider." |
| `swap_panes` | "Swap the build and server panes." |
| `move_pane` | "Move logs below claude-2." |
| `rename_pane` | "Call this pane server." |
| `rename_agent` | "Rename claude-2 to api-claude." |
| `agent_info` | "Why is that agent not showing up?" |
| `pane_processes` | "What programs are running in the build pane?" |
| `run_shell` | "What branch is forge on?" |
| `run_in_pane` | "Run the tests in the build pane." |

Confirmation behavior is unchanged. Only a later real Whisper microphone transcript can satisfy a pending approval;
typed context, reports, model text and tool output cannot. Speech that began over playback is retained as overlapped
provenance and cannot confirm an action.

## Turn-taking

Local mode follows upstream OpenLive's defaults. A turn ends after 560 ms of quiet, so a short pause mid-sentence
doesn't cut you off. Utterances with less than 200 ms of speech-level audio (clicks, coughs, hiss, echo tails) are
dropped before Whisper sees them, because Whisper invents words for noise. A transcript that trails off ("tell claude
to…") is held and joined with what you say next; if you say nothing for 4 s, it's sent as is.

While the voice is talking, echo cancellation still lets some of its own audio into the mic. Mic input quieter than
25% of the playback level doesn't count as speech, so the voice can't interrupt itself; talking over it at a normal
level still does. If it still cuts itself off, raise `HERDR_VOICE_LOCAL_ECHO_RATIO` (for example `0.4`). If talking
over it doesn't stop it, lower it. `HERDR_VOICE_GATE_DEBUG=1` logs mic and playback levels each time the gate opens.

## Latency evidence

The demo's `commitToFirstNonSilentPCMProxyMs` measures input commit to the first returned PCM packet whose absolute
sample reaches 64. It replays packets in real time, but it is not a live-microphone or cloud-comparable benchmark and
does not measure physical speaker onset. Hardware-loopback acoustic measurement is still required for that claim.
The current component evidence already misses the requested 500 ms end-to-end target: warm fp32 Whisper was
about 570–739 ms, Kokoro 470–873 ms, and warm Qwen first-tool events 286–333 ms before complete pipeline overhead.
The target is **unmet**. fp16 Whisper fails its decoder graph; fp16 Kokoro produced non-finite output; q8 TTS was much
slower. The runtime therefore keeps the actual upstream fp32 path and rejects non-finite audio.

The first strict integrated smoke on Apple M4 Pro completed one real `list_agents` call and measured 9,645.5 ms from
commit to first non-silent returned PCM. That single run proves routing, not a latency distribution. Its public summary
is in [`local-openlive-results.json`](local-openlive-results.json), alongside the Linux run below. Ignored WAV and JSONL
artifacts and raw tool output stay outside Git.

On Linux (RTX 4050 Laptop, 6 GB, driver 615.71.10, Vulkan 1.4.351) the helper reports adapter `nvidia`/`lovelace` and
the fp32 probes land in the same range as macOS: 271–334 ms for the silence STT probe, 347–498 ms for the short TTS
phrase, from the strict-offline restart as well as setup. The model cache digest is byte-identical to the macOS run, so
both platforms load the same weights. The integrated demo completed one real `list_agents` call in 6,754.4 ms, but that
run is not a latency sample: it drove the 6 GB card to 5,830 MiB with 24 MiB free, and Dawn logged 200
`VK_ERROR_OUT_OF_DEVICE_MEMORY` failures on `CreateBuffer`, so the number includes work redone after exhaustion. The
full fp32 Whisper + Kokoro working set plus a desktop session leaves no headroom on a 6 GB laptop GPU; a run without
exhaustion, or a card with more memory, is needed before quoting a Linux latency figure. The 500 ms target stays
**unmet** on both platforms.

Vision is unsupported in the native local voice path because Herdr has no permission contract for capturing frames.
