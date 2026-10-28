import Testing
@testable import HerdrVoiceCore

@Test func aSessionTheProviderEndedIsRenewedAtOnce() {
    #expect(Reconnect.delay(provider: .grok, reason: .sessionEnded, attempt: 0, muted: false) == 0)
}

@Test func aLostSocketIsRedialedWhileTheHelperLives() {
    // The port outlives a socket, so a drop — a late keepalive included — must never pay the ~9 s warm-up again.
    #expect(!Reconnect.relaunchesHelper(provider: .local, connectionLost: true, helperAlive: true))
    #expect(!Reconnect.relaunchesHelper(provider: .local, connectionLost: false, helperAlive: false))
    // A host whose process is really gone is the only one relaunched.
    #expect(Reconnect.relaunchesHelper(provider: .local, connectionLost: true, helperAlive: false))
}

@Test func oneMissedKeepaliveNeverRelaunchesTheInferenceHost() {
    // The regression from the reconnect loop: a single unanswered keepalive used to relaunch Local OpenLive, which
    // is what turned one slow beat into a restart cycle. A live helper only ever costs a redial.
    #expect(!Reconnect.relaunchesHelper(provider: .local, connectionLost: true, helperAlive: true))
}

@Test("cloud reconnects never relaunch the local helper", arguments: [Provider.grok, .openai, .gemini])
func cloudReconnectsDoNotRelaunch(provider: Provider) {
    #expect(!Reconnect.relaunchesHelper(provider: provider, connectionLost: true, helperAlive: false))
}

@Test func recapTruncatesTheMatchingPlaybackItem() {
    var recap = Recap()
    recap.add("voice", "first answer", itemID: "first")
    recap.add("you", "next question")
    recap.add("voice", "second answer", itemID: "second")
    recap.replace(itemID: "first", speaker: "voice", with: "first")
    #expect(recap.lines == ["voice: first", "you: next question", "voice: second answer"])
}

@Test func dropsBackOffUpToThirtySecondsThenGiveUp() {
    let delays = (0..<Reconnect.maxAttempts).map {
        Reconnect.delay(provider: .grok, reason: .dropped, attempt: $0, muted: false)
    }
    #expect(delays == [1, 2, 4, 8, 16, 30, 30, 30])
    #expect(Reconnect.delay(provider: .grok, reason: .dropped, attempt: Reconnect.maxAttempts, muted: false) == nil)
    // A session end that keeps failing to renew backs off like a drop.
    #expect(Reconnect.delay(provider: .grok, reason: .sessionEnded, attempt: 2, muted: false) == 4)
}

@Test func aLocalSocketRetryIsFastTieredAndThenGivesUpVisibly() {
    // The helper keeps its warm models, so a socket retry is cheap: sub-second first, never exponential, and bounded
    // so a port that never comes back is reported instead of retried forever.
    let delays = (0..<Reconnect.localSocketAttempts).map {
        Reconnect.delay(provider: .local, reason: .dropped, attempt: $0, muted: false)
    }
    #expect(delays == [0.2, 0.5, 1, 1, 1, 1])
    #expect(Reconnect.delay(provider: .local, reason: .dropped, attempt: Reconnect.localSocketAttempts,
                            muted: false) == nil)
    // A relaunch that fails retries the same way rather than backing off like a cloud drop.
    #expect((Reconnect.delay(provider: .local, reason: .dropped, attempt: 0, muted: false) ?? 99) < 1)
}

@Test func whileMutedItWaitsForTheDeveloper() {
    #expect(Reconnect.delay(provider: .grok, reason: .sessionEnded, attempt: 0, muted: true) == nil)
    #expect(Reconnect.delay(provider: .grok, reason: .dropped, attempt: 0, muted: true) == nil)
    #expect(Reconnect.delay(provider: .local, reason: .dropped, attempt: 0, muted: true) == nil)
}

@Test("routine session ends are recognized", arguments: [
    "Conversation timed out after 900.0 seconds due to inactivity",   // xAI, seen live
    "Your session hit the maximum duration of 60 minutes.",            // OpenAI
    "session_expired",
])
func sessionEndsAreRecognized(message: String) { #expect(Reconnect.isSessionEnd(message)) }

@Test("real errors are not mistaken for session ends", arguments: [
    "Invalid API key", "Rate limit exceeded", "The request timed out",
])
func realErrorsAreNot(message: String) { #expect(!Reconnect.isSessionEnd(message)) }

@Test func recapKeepsTheLastLinesTrimmedAndCapped() {
    var r = Recap(limit: 3)
    #expect(r.message == nil)
    r.add("you", "  tell claude-2 to run the tests  ")
    r.add("voice", "Sent.")
    r.add("you", "")                                      // ignored
    r.add("voice", String(repeating: "x", count: 400))    // capped
    r.add("you", "what did it do?")
    #expect(r.lines.count == 3)
    #expect(r.lines.first == "voice: Sent.")
    #expect(r.lines[1].hasSuffix("…") && r.lines[1].count == "voice: ".count + 301)
    #expect(r.message?.hasPrefix("[context] The connection was renewed.") == true)
    #expect(r.message?.hasSuffix("you: what did it do?") == true)
}
