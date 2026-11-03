import Foundation

/// Reassembles JSON messages out of WebSocket text frames.
///
/// swift-corelibs-foundation does not hand back a WebSocket message whole: anything past roughly 4 KB arrives as
/// consecutive `receive()` results, so a 6.5 KB audio delta is delivered as a 4092-character head and a
/// 2381-character tail. Decoding each result on its own fails — that was the `✖ undecodable event` flood on Linux —
/// and the audio inside it was thrown away. Darwin delivers whole messages, so this is a no-op there.
///
/// The assembler keeps the text it cannot decode yet and returns every complete top-level JSON object it finds.
/// It tracks string and escape state, so a `{` or `}` inside a string neither nests nor ends an object, and an
/// escape split across two fragments is remembered instead of being read as a closing quote.
public struct TextFrameAssembler {
    /// An object that never completes is dropped past this size: a peer streaming a broken object forever must not
    /// grow the buffer without bound. Real frames here are audio deltas of a few kilobytes.
    private let limit: Int

    /// Bytes of the object being assembled, from its opening `{`.
    private var object: [UInt8] = []
    /// Nesting depth of the object in `object`. Zero means nothing is being assembled.
    private var depth = 0
    private var inString = false
    private var escaped = false

    public init(limit: Int = 4 << 20) { self.limit = limit }

    /// Bytes held for an object that is still incomplete.
    public var pendingBytes: Int { object.count }

    /// Forgets an unfinished object. Call this when the socket changes: a fragment from one connection must never be
    /// stitched onto another's.
    public mutating func reset() {
        object.removeAll(keepingCapacity: true)
        depth = 0
        inString = false
        escaped = false
    }

    /// Feeds one received frame and returns the messages it completed, in order.
    public mutating func push(_ frame: String) -> [String] { push(Array(frame.utf8)) }

    public mutating func push(_ bytes: [UInt8]) -> [String] {
        var complete: [String] = []
        for byte in bytes {
            // Between messages: anything that is not the start of an object is not ours to keep.
            guard depth > 0 else {
                guard byte == UInt8(ascii: "{") else { continue }
                depth = 1
                object = [byte]
                continue
            }
            object.append(byte)
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "{") {
                depth += 1
            } else if byte == UInt8(ascii: "}") {
                depth -= 1
                if depth == 0 {
                    complete.append(String(decoding: object, as: UTF8.self))
                    object.removeAll(keepingCapacity: true)
                    inString = false
                    escaped = false
                }
            }
            if object.count > limit { reset() }
        }
        return complete
    }
}
