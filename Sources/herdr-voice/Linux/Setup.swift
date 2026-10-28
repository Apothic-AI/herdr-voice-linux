import Foundation
import HerdrVoiceCore

#if canImport(Glibc)
import Glibc
#endif

/// `herdr-voice setup`: asks for the provider's API key with hidden input and saves it in the platform secret store.
/// Returns whether a key was saved.
///
/// Linux uses the Secret Service when one is reachable and a private 0600 file when it isn't (see Keychain), so
/// the wording follows whichever store is actually in use.
func setupKey(for provider: Provider) -> Bool {
    print("""
    Set up \(provider.menuTitle) for herdr-voice.
      1. Create an API key at \(provider.keyPage)
      2. Paste it below. Typing is hidden; it goes straight into your \(Keychain.storeDescription) as \(provider.keyEnv).

    """)
    guard let raw = readHidden("\(provider.menuTitle) API key: ") else {
        print("✖ couldn't read from the terminal; run this in an interactive terminal")
        return false
    }
    guard let key = Keychain.cleanKey(raw) else {
        print("✖ that doesn't look like an API key (empty, or it has spaces or other characters keys don't use); nothing saved")
        return false
    }
    if !key.hasPrefix(provider.keyPrefix) {
        print("⚠ \(provider.menuTitle) keys start with \"\(provider.keyPrefix)\" and this one doesn't. Save it anyway? [y/N] ", terminator: "")
        guard readLine()?.lowercased().hasPrefix("y") == true else {
            print("nothing saved")
            return false
        }
    }
    guard Keychain.store(service: provider.keyEnv, value: key) else {
        print("✖ couldn't save it in the \(Keychain.storeDescription); set \(provider.keyEnv) in the environment instead")
        return false
    }
    print("✓ saved \(provider.keyEnv) in your \(Keychain.storeDescription). Replace any time with: herdr-voice setup \(provider.rawValue)\n")
    return true
}

/// Reads one line from the terminal with echo turned off, then restores the terminal.
///
/// `readpassphrase` is BSD-only, so Linux turns echo off around a normal read. A non-TTY stdin has no echo to
/// disable and gets read as-is, which is what a piped `echo $KEY | herdr-voice setup` needs.
func readHidden(_ prompt: String) -> String? {
    print(prompt, terminator: "")
    fflush(stdout)
    let fd = STDIN_FILENO
    let isTTY = isatty(fd) == 1
    var saved = termios()
    if isTTY {
        guard tcgetattr(fd, &saved) == 0 else { return readLine() }
        var quiet = saved
        quiet.c_lflag &= ~tcflag_t(ECHO)
        _ = tcsetattr(fd, TCSAFLUSH, &quiet)
    }
    defer {
        if isTTY { _ = tcsetattr(fd, TCSAFLUSH, &saved) }
        print()
    }
    return readLine()
}
