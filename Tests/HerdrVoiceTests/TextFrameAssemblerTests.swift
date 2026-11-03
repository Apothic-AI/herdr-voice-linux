import Foundation
import Testing
@testable import HerdrVoiceCore

// swift-corelibs-foundation hands a WebSocket message above ~4 KB back in pieces, so one provider message can arrive
// as several `receive()` results. Each piece used to be decoded on its own: that logged `✖ undecodable event` and
// dropped the audio in it. These pin the assembler that puts the pieces back together, on the split points that
// actually happen — and on the ones that make naive splitters wrong (a brace inside a string, an escape cut in two).

/// A message with a brace, an escaped quote and an escaped backslash inside its only string value.
private let transcriptFrame = #"{"type":"response.output_audio_transcript.done","transcript":"a } brace, a \" quote, a \\ backslash"}"#
/// What that string value is once JSON has unescaped it.
private let transcriptText = "a } brace, a \" quote, a \\ backslash"

private func decode(_ frame: String) -> [ServerEvent] { [ServerEvent.decode(frame)] }

@Suite struct TextFrameAssemblerTests {
    @Test func wholeFramePassesStraightThrough() {
        var assembler = TextFrameAssembler()
        #expect(assembler.push(transcriptFrame) == [transcriptFrame])
        #expect(assembler.pendingBytes == 0)
    }

    /// The common case: the split lands inside the value, in the middle of a string.
    @Test func splitMidStringReassembles() {
        var assembler = TextFrameAssembler()
        let cut = transcriptFrame.index(transcriptFrame.startIndex, offsetBy: 60)
        #expect(assembler.push(String(transcriptFrame[..<cut])).isEmpty)
        #expect(assembler.pendingBytes > 0)
        let finished = assembler.push(String(transcriptFrame[cut...]))
        #expect(finished == [transcriptFrame])
        #expect(decode(finished[0]) == [.assistantTranscript(transcriptText)])
    }

    /// Cut between the two characters of an escape. The first fragment ends on a lone backslash, which a splitter
    /// that does not remember escape state reads as an escaped quote and then loses the string boundary for good.
    @Test func splitMidEscapeReassembles() throws {
        let pair = try #require(transcriptFrame.range(of: #"\\"#))
        let cut = pair.upperBound // the first fragment ends on a lone backslash
        var assembler = TextFrameAssembler()
        #expect(assembler.push(String(transcriptFrame[..<cut])).isEmpty)
        #expect(assembler.push(String(transcriptFrame[cut...])) == [transcriptFrame])
        #expect(assembler.push(transcriptFrame).count == 1) // the state did not leak into the next message
    }

    /// Cut immediately after the opening brace, and again immediately before the closing one.
    @Test func splitAtBraceBoundariesReassembles() {
        let afterOpening = transcriptFrame.index(after: transcriptFrame.startIndex)
        let beforeClosing = transcriptFrame.index(before: transcriptFrame.endIndex)
        for cut in [afterOpening, beforeClosing] {
            var assembler = TextFrameAssembler()
            #expect(assembler.push(String(transcriptFrame[..<cut])).isEmpty)
            #expect(assembler.push(String(transcriptFrame[cut...])) == [transcriptFrame])
        }
    }

    /// Many fragments, not two: corelibs splits at its own size, not at anything the protocol respects.
    @Test func manyFragmentsReassemble() {
        var assembler = TextFrameAssembler()
        var rebuilt: [String] = []
        let bytes = Array(transcriptFrame.utf8)
        for start in stride(from: 0, to: bytes.count, by: 7) {
            rebuilt += assembler.push(Array(bytes[start..<min(start + 7, bytes.count)]))
        }
        #expect(rebuilt == [transcriptFrame])
    }

    /// The exact signature measured on Linux: a 6.5 KB audio delta delivered as 4092 + 2381 characters.
    @Test func audioDeltaSplitLikeCorelibsReassembles() {
        let payload = Data((0 ..< 4800).map { UInt8($0 % 251) }).base64EncodedString()
        let frame = #"{"type":"response.output_audio.delta","item_id":"item_3","delta":"\#(payload)"}"#
        #expect(frame.count > 4096)
        let cut = frame.index(frame.startIndex, offsetBy: 4092)
        var assembler = TextFrameAssembler()
        #expect(assembler.push(String(frame[..<cut])).isEmpty)
        let finished = assembler.push(String(frame[cut...]))
        #expect(finished == [frame])
        guard case .audioDelta(let item, let base64) = ServerEvent.decode(finished[0]) else {
            Issue.record("expected an audio delta, got \(ServerEvent.decode(finished[0]))")
            return
        }
        #expect(item == "item_3")
        #expect(base64 == payload)
    }

    /// Two messages in one frame are two messages.
    @Test func coalescedFramesSplitIntoMessages() {
        var assembler = TextFrameAssembler()
        let pair = #"{"type":"response.created","response":{"id":"resp_1"}}"# + "\n"
            + #"{"type":"input_audio_buffer.speech_started"}"#
        let finished = assembler.push(pair)
        #expect(finished.count == 2)
        #expect(finished.map { ServerEvent.decode($0) } == [.responseCreated, .speechStarted])
    }

    /// A brace inside a string is not structure, and a truncated message is not a message.
    @Test func bracesInStringsDoNotEndAnObject() {
        var assembler = TextFrameAssembler()
        let halves = transcriptFrame.split(separator: "brace", omittingEmptySubsequences: false)
        #expect(assembler.push(halves[0] + "brace").isEmpty) // `}` seen, but inside the string: still incomplete
        #expect(assembler.push(String(halves[1])) == [transcriptFrame])
    }

    /// A new connection never inherits the previous one's half-message.
    @Test func resetDropsAnUnfinishedObject() {
        var assembler = TextFrameAssembler()
        _ = assembler.push(String(transcriptFrame.prefix(40)))
        #expect(assembler.pendingBytes > 0)
        assembler.reset()
        #expect(assembler.pendingBytes == 0)
        #expect(assembler.push(String(transcriptFrame.suffix(20))).isEmpty) // no closing brace, so nothing completes
        #expect(assembler.push(transcriptFrame) == [transcriptFrame])
    }

    /// Binary frames (Gemini Live) go through the same assembler.
    @Test func binaryFrameBytesAssemble() {
        var assembler = TextFrameAssembler()
        let bytes = Array(transcriptFrame.utf8)
        #expect(assembler.push(Array(bytes[..<25])).isEmpty)
        #expect(assembler.push(Array(bytes[25...])) == [transcriptFrame])
    }
}
