import Foundation

/// When to reconnect after the realtime connection closes.
public enum Reconnect {
    public enum Reason: Equatable {
        /// The provider ended the session on purpose: xAI after 15 minutes idle ("Conversation timed out after 900.0
        /// seconds due to inactivity"), OpenAI at its fixed 60-minute session limit ("session expired").
        case sessionEnded
        /// Network drop, dead socket (found by the keepalive ping), or a failed connect.
        case dropped
    }

    /// Consecutive failed attempts before giving up and waiting for ⌥⌘M (e.g. a revoked key fails every time).
    public static let maxAttempts = 8

    /// Seconds to wait before reconnecting, or nil to stop and say so.
    /// - While muted nothing is listening, so no session is opened until unmute (providers bill by the minute).
    /// - A session the provider ended on purpose is renewed at once; cloud drops back off 1, 2, 4 … 30 s.
    /// - A local helper keeps its warm models, so its socket retries are fast and tiered instead of exponential.
    public static func delay(provider: Provider, reason: Reason, attempt: Int, muted: Bool) -> TimeInterval? {
        guard !muted else { return nil }
        if provider == .local {
            guard attempt < localSocketAttempts else { return nil }
            return localSocketDelays[min(attempt, localSocketDelays.count - 1)]
        }
        guard attempt < maxAttempts else { return nil }
        if reason == .sessionEnded && attempt == 0 { return 0 }
        return min(30, pow(2, Double(attempt)))
    }

    /// Socket retries against a live local helper before the app stops and says so. A retry is cheap because the models
    /// stay warm; a port that never comes back belongs to a host that cannot serve, and looping on it forever is worse
    /// than saying so once and leaving the pane usable.
    public static let localSocketAttempts = 6

    /// Socket retries, fastest first: a reconnect inside a second is not worth mentioning, so the session is back
    /// before anyone notices it went anywhere.
    public static let localSocketDelays: [TimeInterval] = [0.2, 0.5, 1]

    /// Relaunches in a row before the app stops trying. Each one reloads the models, so a host that dies again right
    /// away is reported once instead of respawned in a loop.
    public static let maxRelaunches = 2

    /// Whether the next connect must relaunch the Local OpenLive inference host instead of redialing its port.
    ///
    /// A lost socket is not a dead host: the helper is a long-lived Electron process that takes ~9 s to warm up, and
    /// its loopback port stays valid for as long as it lives, so a drop — a late keepalive included — is redialed on
    /// the same port, models and all. Only a host whose process is actually gone is relaunched; a live host that stops
    /// answering is retried and then reported (see `localSocketAttempts`), never silently replaced.
    public static func relaunchesHelper(provider: Provider, connectionLost: Bool, helperAlive: Bool) -> Bool {
        provider == .local && connectionLost && !helperAlive
    }

    /// Whether a server error message announces a routine session end (idle timeout or maximum duration)
    /// rather than a real failure.
    public static func isSessionEnd(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("inactivity") || (m.contains("timed out") && m.contains("conversation"))
            || m.contains("session expired") || m.contains("session_expired") || m.contains("maximum duration")
    }
}

/// The last few things said, so a new session after a reconnect still knows what the conversation was about.
public struct Recap {
    public let limit: Int
    public private(set) var lines: [String] = []
    private var itemIDs: [String?] = []

    public init(limit: Int = 12) { self.limit = limit }

    public mutating func add(_ speaker: String, _ text: String, itemID: String? = nil) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        lines.append("\(speaker): \(t.count > 300 ? String(t.prefix(300)) + "…" : t)")
        itemIDs.append(itemID)
        if lines.count > limit {
            let excess = lines.count - limit
            lines.removeFirst(excess)
            itemIDs.removeFirst(excess)
        }
    }

    public mutating func replace(itemID: String, speaker: String, with text: String) {
        guard let index = itemIDs.lastIndex(where: { $0 == itemID }) else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            lines.remove(at: index)
            itemIDs.remove(at: index)
        } else {
            lines[index] = "\(speaker): \(value.count > 300 ? String(value.prefix(300)) + "…" : value)"
        }
    }

    /// The context message for a fresh session, or nil when nothing was said yet.
    public var message: String? {
        guard !lines.isEmpty else { return nil }
        return "[context] The connection was renewed. The conversation so far, most recent last; don't reply to "
            + "this, just keep it in mind:\n" + lines.joined(separator: "\n")
    }
}
