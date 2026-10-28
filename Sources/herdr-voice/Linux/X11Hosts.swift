import Foundation
import HerdrVoiceCore

#if canImport(Glibc)
import Glibc
#endif

/// Finds the terminal process that owns the window Herdr is running in, by walking `/proc`.
///
/// This is the primary way to find the host window on X11, because the title is not a reliable signal: a
/// terminal's window title follows whatever the active tab is running, so a Herdr session in a tab titled after
/// something else (a browser tab name, a task) never mentions "herdr" at all. The process tree always does: the
/// shell that started `herdr` was started by the terminal, and on Linux that terminal either *is* the window
/// owner (xterm, kitty, alacritty, foot…) or is the shared server that owns every window of that terminal
/// (gnome-terminal-server, konsole — one process, many windows).
///
/// `WindowPin.hostApp` is the same walk the macOS tracker does, with "is this a terminal?" standing in for
/// "is this a regular GUI app?".
enum X11Hosts {
    /// Terminal names, matched as prefixes of the executable's basename so `gnome-terminal-server` and
    /// `gnome-terminal-…` are covered, and so are the several spellings of the same emulator.
    private static let terminals = [
        "gnome-terminal", "kgx", "ptyxis", "xterm", "kitty", "alacritty", "konsole", "wezterm", "tilix", "foot",
        "ghostty", "terminator", "urxvt", "rxvt", "st", "eterm", "lxterminal", "xfce4-terminal", "mate-terminal",
        "tabby", "warp", "blackbox", "cool-retro-term",
    ]

    /// Every distinct terminal process that hosts this process, or any `herdr` process alive right now.
    ///
    /// Starting from every `herdr` and not just ourselves covers a server that outlived the client which started
    /// it: then the attached clients are the ones with the terminal in their ancestry.
    static func hostPIDs() -> Set<Int32> {
        var starts = [getpid()]
        starts += allPIDs().filter { processName($0) == "herdr" }
        var hosts = Set<Int32>()
        for start in starts {
            if let host = WindowPin.hostApp(from: start, parent: parentPID, isRegularApp: isTerminal) {
                hosts.insert(host)
            }
        }
        return hosts
    }

    /// Whether the process is a terminal emulator — the thing that would own the window.
    private static func isTerminal(_ pid: Int32) -> Bool {
        let name = processName(pid)
        guard !name.isEmpty else { return false }
        let lowered = name.lowercased()
        return terminals.contains { lowered.hasPrefix($0) }
    }

    /// The executable's own name: `cmdline` rather than `comm`, because `comm` is truncated to 15 characters and
    /// turns `gnome-terminal-server` into `gnome-terminal-`.
    private static func processName(_ pid: Int32) -> String {
        if let raw = try? String(contentsOfFile: "/proc/\(pid)/cmdline", encoding: .utf8) {
            let argv = raw.split(separator: "\0", omittingEmptySubsequences: true)
            if let first = argv.first, let name = first.split(separator: "/").last, !name.isEmpty {
                return String(name)
            }
        }
        return (try? String(contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// `ppid` from `/proc/<pid>/stat`.
    ///
    /// The second field is the command name in parentheses and may itself contain spaces and parentheses, so the
    /// fields are counted after the *last* `)`; the first of those is the state and the second is the parent pid.
    private static func parentPID(_ pid: Int32) -> Int32? {
        guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = stat.lastIndex(of: ")")
        else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        guard fields.count > 1 else { return nil }
        return Int32(fields[1])
    }

    private static func allPIDs() -> [Int32] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return [] }
        return entries.compactMap { Int32($0) }
    }
}
