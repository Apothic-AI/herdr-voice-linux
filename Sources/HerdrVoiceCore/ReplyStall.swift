import Foundation

/// Decides when a reply that has gone quiet is dead rather than slow.
///
/// The microphone onset is suppressed while a reply is on its way, so that a noise cannot bump the wire's epoch and
/// leave a tool result the previous turn was waiting for stale. That suppression needs a bound: the local helper
/// answers a request with `response.created` and then, when its greeting produces nothing, never sends another event at
/// all. The flag then stays true for the rest of the session, every gate opening is suppressed, `input.begin` is never
/// sent, and not one audio frame reaches the provider — the microphone is deaf and nothing says so.
///
/// Three things keep a legitimate reply alive: it is audible (so it is arriving), it has a tool call in flight (so the
/// wait is real), or it said something about the conversation recently. Only when none of those hold does the timeout
/// apply.
public struct ReplyStall: Equatable {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// - Parameters:
    ///   - lastEvent: when the provider last said anything about the conversation — not a heartbeat, which proves the
    ///     socket is open and nothing more.
    ///   - pending: a reply has been asked for, or is being generated, and has not been heard yet.
    public func isStalled(now: Date, lastEvent: Date, audible: Bool, callsInFlight: Int, pending: Bool) -> Bool {
        guard pending, !audible, callsInFlight == 0 else { return false }
        return now.timeIntervalSince(lastEvent) > timeout
    }
}