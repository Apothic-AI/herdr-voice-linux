import Foundation

/// Stores provider API keys in the platform's secret store.
///
/// macOS keeps them in the login Keychain, read through /usr/bin/security rather than SecItem: an item added with
/// `security add-generic-password` trusts that tool, so reading it this way never prompts. SecItem from this
/// unsigned binary would prompt again after every rebuild, since each build has a different code signature. The
/// secret only travels over a private pipe: the command line carries just the service name, and stderr
/// ("item not found") is discarded.
///
/// Linux keeps them in the Secret Service (GNOME Keyring, KWallet) through `secret-tool`, again over stdin. Where
/// no keyring is reachable (a bare TTY, a container, CI) it falls back to a private file under
/// `$XDG_CONFIG_HOME/herdr-voice/secrets` with 0600 permissions, so setup never dead-ends.
/// HERDR_VOICE_KEYRING forces a backend (`file`, `secret-tool`, `off`); HERDR_VOICE_SECRETS_DIR moves the file
/// store.
public enum Keychain {
    public enum Backend: String, Sendable {
        case security
        case secretTool = "secret-tool"
        case file
        case off
    }

    /// A pasted key, tidied: surrounding whitespace and quotes dropped. Nil unless what's left is only the
    /// characters API keys use, which also keeps it safe inside the quoted commands below.
    public static func cleanKey(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !key.isEmpty,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })
        else { return nil }
        return key
    }

    /// Where a key is kept, for help text.
    public static var storeDescription: String {
        switch backend {
        case .security: return "Keychain"
        case .secretTool: return "secret service"
        case .file: return "local key file"
        case .off: return "nowhere (HERDR_VOICE_KEYRING=off)"
        }
    }

    /// Runs a helper with stdin closed and returns stdout, or nil when it exits non-zero. Never passes a secret on
    /// the command line.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return data
    }

    #if os(macOS)
    // MARK: - macOS: the login Keychain through /usr/bin/security

    public static var backend: Backend { .security }

    /// The `security -i` command line that saves (or replaces) `value`. Sent over a pipe, never as an argument,
    /// so the key doesn't show up in the process list or shell history. `value` must come from `cleanKey`.
    static func storeCommand(service: String, account: String, value: String) -> String {
        "add-generic-password -U -a \"\(account)\" -s \(service) -l \"herdr-voice \(service)\" -w \"\(value)\"\n"
    }

    public static func store(service: String, value: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        input.fileHandleForWriting.write(
            Data(storeCommand(service: service, account: NSUserName(), value: value).utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0 && password(service: service) == value
    }

    public static func password(service: String) -> String? {
        guard let out = run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"]) else { return nil }
        let value = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    public static func delete(service: String) {
        _ = run("/usr/bin/security", ["delete-generic-password", "-s", service])
    }

    #else
    // MARK: - Linux: Secret Service through secret-tool, else a private file

    /// Which backend is in use. HERDR_VOICE_KEYRING picks one; otherwise secret-tool when the Secret Service is
    /// reachable, and the file store when it isn't.
    public static var backend: Backend {
        if let forced = ProcessInfo.processInfo.environment["HERDR_VOICE_KEYRING"]
            .flatMap({ Backend(rawValue: $0) }) {
            return forced
        }
        if secretTool != nil, secretServiceReachable { return .secretTool }
        return .file
    }

    static let secretTool = ["/usr/bin/secret-tool", "/usr/local/bin/secret-tool", "/bin/secret-tool"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// secret-tool talks D-Bus; without a session bus there is no Secret Service to talk to.
    static var secretServiceReachable: Bool {
        if let address = ProcessInfo.processInfo.environment["DBUS_SESSION_BUS_ADDRESS"], !address.isEmpty {
            return true
        }
        return FileManager.default.fileExists(atPath: "/run/user/\(getuid())/bus")
    }

    /// The private fallback store. Not the Keychain's equal (the key is on disk), so it is only used where no
    /// keyring exists, and the file is 0600 inside a 0700 directory.
    static var secretsDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["HERDR_VOICE_SECRETS_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: NSString(string: dir).expandingTildeInPath, isDirectory: true)
        }
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { NSString(string: $0).expandingTildeInPath } ?? NSHomeDirectory() + "/.config"
        return URL(fileURLWithPath: base + "/herdr-voice/secrets", isDirectory: true)
    }

    static func secretFile(_ service: String) -> URL {
        let safe = String(service.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return secretsDirectory.appendingPathComponent(safe)
    }

    public static func store(service: String, value: String) -> Bool {
        switch backend {
        case .secretTool: return storeInSecretService(service: service, value: value)
        case .file: return storeInFile(service: service, value: value)
        case .off, .security: return false
        }
    }

    public static func password(service: String) -> String? {
        switch backend {
        case .secretTool: return passwordFromSecretService(service: service) ?? readFile(service: service)
        case .file: return readFile(service: service)
        case .off, .security: return nil
        }
    }

    public static func delete(service: String) {
        if backend == .secretTool, let tool = secretTool {
            _ = run(tool, ["clear", "service", service, "application", "herdr-voice"])
        }
        try? FileManager.default.removeItem(at: secretFile(service))
    }

    static func storeInSecretService(service: String, value: String) -> Bool {
        guard let tool = secretTool else { return storeInFile(service: service, value: value) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["store", "--label", "herdr-voice \(service)", "service", service,
                       "application", "herdr-voice"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return storeInFile(service: service, value: value) }
        input.fileHandleForWriting.write(Data(value.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        // Only claim success when it reads back: a locked keyring makes `store` fail quietly.
        if p.terminationStatus == 0, passwordFromSecretService(service: service) == value { return true }
        return storeInFile(service: service, value: value)
    }

    static func passwordFromSecretService(service: String) -> String? {
        guard let tool = secretTool,
              let out = run(tool, ["lookup", "service", service, "application", "herdr-voice"])
        else { return nil }
        let value = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    static func storeInFile(service: String, value: String) -> Bool {
        let dir = secretsDirectory
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            let file = secretFile(service)
            try Data(value.utf8).write(to: file, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            return readFile(service: service) == value
        } catch {
            return false
        }
    }

    static func readFile(service: String) -> String? {
        guard let data = try? Data(contentsOf: secretFile(service)) else { return nil }
        let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }
    #endif
}
