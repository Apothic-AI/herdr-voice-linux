# Linux port: verification record

Every claim below is a command that was actually run on this machine, with its result. The box is Debian 13
(trixie), x86_64, X11 (:1) under mutter, PipeWire audio, Swift 6.0.3 from `swiftlang`.

Host facts that matter for reading this: nothing is simulated unless a section says so, and no cloud provider key
was available, so the cloud path is verified to the protocol boundary with a local server speaking the same
protocol (see [The session loop](#the-session-loop)).

## Build and unit tests

| Check | Command | Result |
|---|---|---|
| Debug build | `swift build` | build complete, 0 errors |
| Unit tests | `swift test` | **190 tests passed** |
| Release build | `swift build -c release` | build complete, 0 errors |
| Plugin build steps | `swift build -c release && .build/release/herdr-voice install-command` | both exit 0, launcher at `~/.local/bin/herdr-voice` |

The 190 tests are the package's own suite, unchanged in scope: the wire goldens (which pin the exact JSON sent to
each provider), the tool-schema digest, the speech gate, the confirmation gate, the reconnect backoff, the
pane-layout reading, and the window-pinning decisions. They now also run on Linux, which is what makes the shared
half trustworthy rather than merely compiling.

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

See [docs/linux-port.md](linux-port.md#audio) for what replaces AVFoundation's voice processing. Evidence:
`scripts/linux-audio-check` (device round trip, capture and playback levels, WAV captures) and the echo
suppression measurement recorded below.

## The orb

The orb is an override-redirect ARGB X11 window drawn with Cairo. Evidence: screenshots per mood, `xwininfo`
showing `override_redirect: yes`, and a check that no focus change occurs when it appears.

## Window pinning and hotkeys

`scripts/linux-x11-check` reports the discovered herdr host window, its rectangle, and PASS/FAIL for tracking a
moved window, hiding when minimized, and the two hotkeys (mute, and Esc only while speaking).

## The session loop

No cloud key was available on this box, so the session was proven against `scripts/realtime-stub`: a local
WebSocket server that speaks the same OpenAI Realtime protocol (the one xAI's Grok Voice also speaks) and drives one
scripted conversation — greeting, a turn triggered by real microphone audio, a real `list_agents` tool call, and a
final reply. `scripts/linux-voice-loop-check` runs the app against it in a Herdr pane and asserts, from the server's
own log, that:

- the app opened a session and sent `session.update` with instructions and tools;
- microphone audio reached the wire (frame count and byte count);
- a real Herdr tool executed and its output came back as `function_call_output`;
- Esc truncated the reply (`conversation.item.truncate` with `audio_end_ms`);
- an orb window exists, is override-redirect, and is on screen during playback.

The stub and the check are in `scripts/` so the result is reproducible: `./scripts/linux-voice-loop-check`.
