# herdr-voice on Linux

herdr-voice was a macOS-only package: AppKit for the orb, AVFoundation for the microphone, Carbon for the global
hotkeys, CoreGraphics for window tracking, the Keychain for API keys. This document describes the port, what
replaces each of those pieces, and how the result was verified.

The goal is feature parity, not a subset. Everything the voice does — the always-open mic, the orb pinned to the
Herdr terminal, spoken tool calls against Herdr, the confirmation gate, watches, the model menu, Local OpenLive —
works on Linux, with the platform's own machinery behind the same contract.

## Shape of the port

The package is one app with two platform halves:

```
Sources/HerdrVoiceCore/          portable: wires, Herdr tools, orb mood maths, WindowPin decisions
Sources/herdr-voice/
  main.swift                     shared: CLI, session, frame callback, tool dispatch
  Realtime.swift                 shared: the voice session
  Commands.swift                 shared: install-command, stop, voice pane
  LocalRuntime.swift             shared: launches the Local OpenLive helper
  WebSocketCompat.swift          shared: one send/receive shape for both Foundations
  macOS/                         Audio, Orb, Hotkey, WindowTracker, Setup, AppHost (AppKit)
  Linux/                         Audio, Orb, Hotkey, WindowTracker, Setup, AppHost (X11/PortAudio)
Sources/CPortAudio, CX11, CCairo  system-library shims, Linux only (pkg-config driven)
```

`Package.swift` compiles exactly one platform directory and excludes the other, so a macOS build never sees Xlib and
a Linux build never sees AppKit. No file contains both implementations.

The portable half builds and is tested on both platforms — 190 tests, including the wire goldens, the tool-schema
digest, the speech gate and the window-pinning decisions.

## What replaces what

| macOS | Linux | Notes |
|---|---|---|
| AVFoundation `AVAudioEngine` + Apple voice processing | PortAudio duplex stream + a software canceller | The always-open mic, 20 ms chunks, and 24 kHz mono PCM16 are unchanged; the echo canceller is now the app's own adaptive filter when the system offers none. See [Audio](#audio). |
| AppKit `NSPanel` of `CAGradientLayer`s | X11 override-redirect ARGB window drawn with Cairo | Same five moods, same blob motion, same thinking bubble. See [The orb](#the-orb). |
| Carbon `RegisterEventHotKey` | `XGrabKey` on the root window | ⌥⌘M becomes Ctrl+Alt+M; Esc is still grabbed only while the voice is speaking. |
| `CGWindowList` + `NSWorkspace` front-app tracking | EWMH `_NET_CLIENT_LIST` + `/proc` process ancestry | Decides which window is "the terminal showing Herdr" and keeps the orb glued inside its bottom-left corner. |
| Login Keychain via `/usr/bin/security` | Secret Service via `secret-tool`, else a private 0600 file | `herdr-voice setup` works the same; the wording follows the store actually in use. |
| `NSApplication.run()` | `CFRunLoopRun()` | Verified that Linux's CFRunLoop drains `DispatchQueue.main`, RunLoop timers and cross-thread dispatch, which is what the session relies on. |
| `CryptoKit.SHA256` | a local SHA-256 | The tool-manifest digest is a wire contract; it must be byte-identical, and it is (golden tests). |
| `os_unfair_lock` / `OSAllocatedUnfairLock` | `UnfairLock` / `Locked` over pthread mutexes | Kept real-time-safe: the audio callback only ever *tries* the lock. |
| `CoreGraphics.CGRect` | `Rect` in HerdrVoiceCore | The pinning logic is pure and tested on both platforms. |
| Foundation's `URLSessionWebSocketTask` completion handlers | `WebSocketCompat` over the async API | swift-corelibs-foundation ships only the async forms. |

## Building

Swift 5.10 or later (Debian 13 ships 6.0.3 as `swiftlang`). The Linux halves link against X11, Xrender, Cairo and
PortAudio, found through `pkg-config`:

```bash
# Debian/Ubuntu
sudo apt install swiftlang libx11-dev libxrender-dev libcairo2-dev portaudio19-dev
# Fedora
sudo dnf install swift-lang libX11-devel libXrender-devel cairo-devel portaudio-devel
# Arch
sudo pacman -S swift libx11 libxrender cairo portaudio

swift build -c release
./.build/release/herdr-voice install-command
```

As a Herdr plugin the same two commands are the manifest's build steps, so `herdr plugin install` works unchanged.

## Audio

The contract is identical to the macOS class, because the session calls it the same way: `start()`, `play`,
`interrupt`, `setMuted`, `isSpeaking`, `onMic`, `onSpeakingChanged`, `micLevel`, `outLevel`.

What matters for a voice app is that the mic can stay open while the assistant speaks, without the assistant
hearing itself. macOS gets that from the OS. On Linux:

1. If PipeWire/PulseAudio exposes an echo-cancel source, it is used.
2. Otherwise the app runs its own adaptive canceller (NLMS) against the known playback reference, which is the
   signal it just sent to the speakers.
3. Muting bypasses the canceller (nothing is being sent, so the cost is pointless) while playback continues.

The measured echo suppression on this machine is recorded in the port verification notes below.

## The orb

The macOS orb is a panel of gradient layers: a soft glow, a rounded sphere, four colour blobs on out-of-phase paths
composited with a screen blend, a specular highlight, a core that pulses with the assistant's voice, and a thinking
bubble with three pulsing dots. The Linux orb keeps that picture:

- an **override-redirect** ARGB window, so the window manager never manages it: it floats above other windows, has
  no taskbar entry, and never takes focus (which is what keeps keystrokes going to the terminal);
- **Cairo** radial gradients for the glow, base, blobs, core and highlight, blended the same way, with the same
  palettes per mood;
- a frame loop at 60 fps while the voice is active and 30 fps while idle, with the same quiet-while-idle CPU idea;
- left click mutes, right click (or Ctrl+click) opens the model menu built fresh from `menuChoices()`, with
  checkmarks, greyed-out unavailable models, separators and Quit;
- `follow(Rect?)` pins it to the Herdr terminal's bottom-left corner, `nil` hides it, and a once-a-second watchdog
  puts it back if something hid it.

## Behaviour that differs, on purpose

- **The mute hotkey is Ctrl+Alt+M** (`HERDR_VOICE_HOTKEY_KEY` / `HERDR_VOICE_HOTKEY_MODS` change it), because Linux
  has no ⌥⌘.
- **Secrets** live in the Secret Service when one is reachable, and otherwise in a 0600 file under
  `$XDG_CONFIG_HOME/herdr-voice/secrets` (a TTY or a container often has no keyring). `HERDR_VOICE_KEYRING` forces
  a backend.
- **`run_shell`** runs in `$SHELL` rather than always `/bin/zsh`.
- **Session type**: Linux support targets X11. Under Wayland the orb, the window tracking and the global hotkey need
  XWayland; native Wayland would need layer-shell and a different input-inhibit story, which this port does not
  claim.

## Verification

The evidence for each feature (commands, exit codes, captured artifacts) is recorded in
[`docs/linux-port-verification.md`](linux-port-verification.md).
