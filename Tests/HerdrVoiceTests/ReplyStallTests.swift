import Foundation
import Testing
@testable import HerdrVoiceCore

/// A fixed clock, so nothing here depends on how fast the machine runs.
private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let stall = ReplyStall(timeout: 20)
private func silentFor(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

@Test func aReplyThatSaysNothingForTooLongIsSettled() {
    // The local helper's failure: `response.created`, then no audio, no transcript and no event at all.
    #expect(stall.isStalled(now: now, lastEvent: silentFor(21), audible: false, callsInFlight: 0, pending: true))
}

@Test func aReplyWeCanHearIsNotStalled() {
    #expect(!stall.isStalled(now: now, lastEvent: silentFor(60), audible: true, callsInFlight: 0, pending: true))
}

@Test func aToolCallWeAreWaitingOnIsNotStalled() {
    // The wait is real and its result is coming; abandoning it here is what used to make the voice go silent.
    #expect(!stall.isStalled(now: now, lastEvent: silentFor(120), audible: false, callsInFlight: 1, pending: true))
}

@Test func aReplyThatSaidSomethingRecentlyIsNotStalled() {
    #expect(!stall.isStalled(now: now, lastEvent: silentFor(19), audible: false, callsInFlight: 0, pending: true))
}

@Test func nothingIsPendingSoNothingIsStalled() {
    #expect(!stall.isStalled(now: now, lastEvent: silentFor(600), audible: false, callsInFlight: 0, pending: false))
}