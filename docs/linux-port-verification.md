# Linux port: verification record

Every claim below is a command that was actually run on this machine, with its result. The box is Debian 13
(trixie), x86_64, an **X11** session on `:1` (mutter compositing, `XDG_SESSION_TYPE=x11`), PulseAudio 15.0.0 on
PipeWire 1.4.2, Swift 6.0.3 (`x86_64-pc-linux-gnu`).

Two facts shape how this should be read. Nothing is simulated unless a section says so. And no cloud provider key
exists on this machine, so the cloud path is verified to the protocol boundary — against a local server speaking the
same protocol, plus the golden wire tests — and not against OpenAI, xAI or Google (see
[What is not proven](#what-is-not-proven)).

## Build and unit tests

| Check | Command | Result |
|---|---|---|
| Debug build | `swift build` | `Build complete!`, 0 errors |
| Unit tests | `swift test` | **200 tests passed** |
| Release build | `swift build -c release` | `Build complete! (20.64s)`, 0 errors |
| Plugin build steps | `swift build -c release && .build/release/herdr-voice install-command` | both exit 0, launcher at `~/.local/bin/herdr-voice` |

The 200 tests are the package's own suite plus the 10 added for this port's frame reassembly (the wire goldens,
which pin the exact JSON sent to each provider, the tool-schema digest, the speech gate, the confirmation gate, the
reconnect backoff, the pane-layout reading, the window-pinning decisions, and now the text-frame assembler). They
run on Linux, which is what makes the shared half trustworthy rather than merely compiling.

## The Herdr tool surface

The voice's tools are thin wrappers over the `herdr` CLI, so running them from the shell exercises the same code
the model calls.

| Tool | Command | Result |
|---|---|---|
| `list_agents` | `herdr-voice tool list_agents '{}'` | returned every live agent in the session as JSON |
| `list_workspaces` | `herdr-voice tool list_workspaces '{}'` | returned all workspaces with tab and pane counts |
| `list_panes` | `herdr-voice tool list_panes '{"workspace":"w1J"}'` | returned the panes of the workspace |
| `agent_info` | `herdr-voice tool agent_info '{"target":"orb-lane"}'` | agent kind, state and detection rule |
| `read_pane` | `herdr-voice tool read_pane '{"target":"w1J:p4","lines":2}'` | pane text, wrapped in the untrusted-output envelope |
| `pane_processes` | `herdr-voice tool pane_processes '{"target":"w1J:p4"}'` | "is running: pi" |
| `create_workspace` | `herdr-voice tool create_workspace '{}'` | created a workspace (then closed with `herdr workspace close`) |
| `close_workspace` (gate) | `herdr-voice tool close_workspace '{"target":"w1N","confirmed":true}'` | **refused**: "the developer has not said yes"; the confirmation gate is live on Linux |

That last row is the safety property, not a failure: closing needs a spoken yes bound to the exact target, and a
tool call from the shell cannot satisfy it.

## API keys

`herdr-voice setup grok` with a piped key stored the value in the Secret Service and read it back through the
app's own lookup path; `secret-tool lookup service XAI_API_KEY application herdr-voice` returned it. The value was
then cleared. With no keyring reachable, the same call falls back to a 0600 file under
`$XDG_CONFIG_HOME/herdr-voice/secrets` (covered by a Linux-only unit test that asserts the mode).

## Plugin install

`herdr plugin link <repo>` parses the manifest with `platforms = ["macos", "linux"]`, exposes the `voice` and
`setup` panes and the `start` / `setup` actions, and the manifest's own build steps run green on Linux (see the
table above). The launcher the plugin writes runs: `~/.local/bin/herdr-voice help` prints the CLI usage.

## Audio

`AVAudioEngine`'s voice processing does not exist off macOS, so Linux uses PortAudio for capture and playback and
its own NLMS echo canceller (see [docs/linux-port.md](linux-port.md#audio)). One detail decides a lot here: no
ALSA/PulseAudio device on this box offers platform echo cancellation
(`echo_cancel=false` on all 30 enumerated devices, `platform_echo_cancel_devices=0`), so the canceller in this repo
is the one doing the work, not a driver.

    PULSE_SINK=hv_null ./scripts/linux-audio-check        # exit 0: 9 PASS, 0 fail

| Measurement | Value |
|---|---|
| PortAudio devices enumerated | 30 (default in 12, default out 12) |
| Loopback echo at 700 Hz, canceller off → on | **−17.1 → −85.4 dBFS, suppressed 68.3 dB** (check requires ≥ 15 dB) |
| Canceller ERLE, off → on | 0.0 → 10.0 dB |
| Default path (mic → speaker), AEK-style | 20 ms in / 20 ms out latency, 160 ms AEC tail, **ERLE 26.5 dB** |
| Real-time load | 0.264 s CPU over 5.000 s wall = **5.3 % of one core**, 300 chunks, 0 dropped, 0 underruns |

The check also asserts the capture path delivers its 20 ms chunks on schedule (72 chunks over 1.5 s) and that
playback is measurable at the microphone, so the loopback number is a real acoustic round trip and not a
self-report.

## The orb

The orb is an override-redirect ARGB X11 window drawn with Cairo and `XPutImage`. It prints the window it created,
which is what a test can then check — searching by class or title matches unrelated windows that happen to share
them, and silently checks the wrong window:

    ◎ orb: 96x96 override-redirect window 0x2a00002 on a 32-bit ARGB visual, composited

| Check | Command | Result |
|---|---|---|
| Window geometry | `xwininfo -id 0x2a00002` | `Width: 96`, `Height: 96`, `Depth: 32`, `Visual Class: TrueColor` |
| Unmanaged by the WM | `xwininfo -id 0x2a00002` | `Override Redirect State: yes` |
| Placed bottom-left of the tracked window | `xwininfo -id 0x2a00002` | `Absolute upper-left X: 4, Y: 925` |
| Composited (ARGB path) | app log | the `composited` line above, with `screenshot` captured during playback (`import -window 0x2a00002`) |
| Frame rate | app log | `◎ orb: active, 60 fps` while speaking, `◎ orb: idle, 30 fps` when idle |

The ARGB path is the composited one. Without a compositor there is no alpha to composite, so the orb draws itself
opaque with its own shadow instead — observed on `Xvfb :99`:

    ⚠ orb: no compositor or no ARGB visual here, so the orb is drawn opaque with its own shadow

## Window pinning and hotkeys

    ./scripts/linux-x11-check        # exit 0: 30 PASS, 0 fail

| Behaviour | Measured result |
|---|---|
| Host window discovery | `0x680000a "vici: herdr-voice-linux"`, owned by `gnome-terminal-server` (pid path, not title) |
| Geometry match | published rect `1920x993+0+32` matches X's geometry, frame offset included |
| Tracking a moved window | published rect followed the move in **3 ms** (limit 250 ms) |
| Minimised / unmapped | publishes `hasHost=true` with no rect, so the orb hides; restored, it comes back |
| Polling rate | **10 Hz** while the tracked terminal has focus, **1 Hz** otherwise |
| Mute hotkey | `ctrl+alt+m` grabbed on the root window and fires the handler |
| Esc | grabbed **only while speaking**, released when speech stops, and fired exactly once in that window |
| Hotkey conflicts | second process reports `could not register Ctrl+Alt+M; click the orb to mute`, and `could not grab Esc; say "stop" or talk over the voice instead`, then exits 0 |

Window tracking and hotkeys are X11 by construction (`XGrabKey` on the root window, `_NET_CLIENT_LIST` /
`_NET_WM_*` reads), so on a Wayland session they work only through XWayland — see
[What is not proven](#what-is-not-proven).

## The session loop

No cloud key was available, so the session was proven against `scripts/realtime-stub`: a local WebSocket server
that speaks the same OpenAI Realtime protocol (the one xAI's Grok Voice also speaks) and drives one scripted
conversation — greeting, a turn triggered by real microphone audio, a real `list_agents` tool call, and a final
reply.

    PULSE_SINK=hv_null ./scripts/linux-voice-loop-check      # exit 0: 19 PASS, 0 fail

Playback is routed into a null sink so a check is never audible on the operator's machine, and the mic streams
continuously (`HERDR_VOICE_STREAM=always`) because the app otherwise only sends audio while its speech gate is open
— on a silent machine that is nothing at all.

From the stub's own report (`/tmp/voice-loop-evidence/stub.json`):

| Assertion | Measured |
|---|---|
| The app connected and opened a session | `connected: 1` |
| `session.update` with instructions and tools | `session_updates: 1`, 4 922 instruction chars, **30 tools offered** |
| Microphone audio reached the wire | **170 frames, 163 200 bytes** (3.4 s of 20 ms 24 kHz PCM16), first frame at 1.332 s |
| A real Herdr tool ran and its output came back | `tool_outputs: 1` — a live `list_agents` payload as `function_call_output` |
| Esc interrupted the reply | `truncates: 2` — `item_0 audio_end_ms 400` (barge-in), `item_1 audio_end_ms 1700` (**Esc**, count 1 → 2) |
| The orb was on screen during playback | override-redirect 96×96 ARGB window, screenshot taken mid-playback |
| No decode failures | **0** `undecodable event` lines in the app log |

### The frame-fragmentation bug this closed

The first run of this loop logged `✖ undecodable event` twenty times per session. The cause is not the protocol:
**swift-corelibs-foundation does not deliver a WebSocket message whole.** Anything past roughly 4 KB arrives as
consecutive `receive()` results. A probe against the same stub, using the same client stack, showed every 6.5 KB
audio delta arriving as **4092 characters then 2381 characters** — each fragment failing JSON parse on its own, and
the audio in it being discarded (which is why a reply could be silent while its transcript still printed).

The receive path now buffers text in `TextFrameAssembler` and decodes only complete JSON objects, tracking string
and escape state so a `{` or `}` inside a string changes nothing and an escape split across two fragments is
remembered rather than read as a closing quote. It is a no-op on macOS, where messages arrive whole. The assembler
is pinned by 10 unit tests: split mid-string, mid-escape and at both brace boundaries, a seven-byte-at-a-time
dribble, two messages coalesced into one frame, the measured 4092/2381 signature, and a reset between connections.

## What is not proven

- **No live cloud session.** No OpenAI, xAI or Gemini key exists on this box. What is proven is that the app speaks
  the OpenAI Realtime protocol correctly enough for an independent server implementation to hold a full
  conversation with it, and the golden wire tests pin the exact bytes it sends to each provider. Latency, billing,
  provider-specific VAD behaviour and real Grok Voice audio are therefore **not** measured here.
- **Cloud provider audio is synthetic.** The stub sends a plain tone and fixed transcripts. Nothing here proves
  how the app sounds with real speech, only that it decodes, plays, meters and reports it.
- **The ARGB orb needs a compositor.** Verified on `:1` under mutter. Elsewhere it draws opaque with a shadow, as
  observed on `Xvfb :99`; that fallback is verified to be taken, not pixel-perfect.
- **Wayland is XWayland only.** The whole X11 half (orb window, window tracking, global hotkeys) talks to the X
  server directly. Under a Wayland session it works only as far as XWayland exposes the herdr window and honours
  root-window key grabs; a Wayland session was never tested on this machine.
- **No platform echo cancellation.** The box's devices offer none, so all suppression numbers above come from the
  in-repo NLMS canceller.

## Reproducing it

    ./scripts/linux-audio-check              # device round trip, levels, AEC (PULSE_SINK=hv_null to stay silent)
    ./scripts/linux-x11-check                # window tracking, hide/restore, polling rate, hotkeys, conflicts
    ./scripts/linux-voice-loop-check         # the full loop against the local protocol stub
    swift test                               # 200 tests
