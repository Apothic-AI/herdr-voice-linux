import Foundation
import Testing
@testable import HerdrVoiceCore
#if canImport(Glibc)
import Glibc
#endif

@Test("pasted keys are tidied", arguments: [
    ("  xai-abc123\n", "xai-abc123"),
    ("\"sk-proj-A_b.9\"", "sk-proj-A_b.9"),
    ("'AIzaSyX-1'", "AIzaSyX-1"),
])
func pastedKeysAreCleaned(raw: String, key: String) { #expect(Keychain.cleanKey(raw) == key) }

@Test("anything that isn't a key is refused", arguments: ["", "   ", "xai-abc def", "sk-\"; rm -rf ~", "key\nsecond", "export XAI_API_KEY=xai-1"])
func nonKeysAreRefused(raw: String) { #expect(Keychain.cleanKey(raw) == nil) }

#if os(macOS)
@Test func theKeyTravelsQuotedInOneCommand() {
    let line = Keychain.storeCommand(service: "XAI_API_KEY", account: "me", value: "xai-abc")
    #expect(line == "add-generic-password -U -a \"me\" -s XAI_API_KEY -l \"herdr-voice XAI_API_KEY\" -w \"xai-abc\"\n")
}
#else
/// Linux keeps the key in the Secret Service or a private file, so what matters is the round trip and the file
/// permissions rather than a `security` command line.
@Test func linuxKeyStoreRoundTripsAndKeepsTheFilePrivate() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-voice-keytest-\(UUID().uuidString)")
    setenv("HERDR_VOICE_SECRETS_DIR", dir.path, 1)
    setenv("HERDR_VOICE_KEYRING", "file", 1)
    defer {
        unsetenv("HERDR_VOICE_SECRETS_DIR")
        unsetenv("HERDR_VOICE_KEYRING")
        try? FileManager.default.removeItem(at: dir)
    }
    #expect(Keychain.backend == .file)
    #expect(Keychain.store(service: "XAI_API_KEY", value: "xai-abc"))
    #expect(Keychain.password(service: "XAI_API_KEY") == "xai-abc")
    let file = Keychain.secretFile("XAI_API_KEY")
    let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    #expect(perms?.intValue == 0o600)
    Keychain.delete(service: "XAI_API_KEY")
    #expect(Keychain.password(service: "XAI_API_KEY") == nil)
}
#endif

@Test func eachProviderHasAKeyPageAndPrefix() {
    for p in Provider.allCases where p.requiresAPIKey {
        #expect(p.keyPage.hasPrefix("https://"))
        #expect(!p.keyPrefix.isEmpty)
    }
}
