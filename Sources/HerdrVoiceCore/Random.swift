import Foundation

#if canImport(Security)
import Security
#endif

/// Cryptographically random bytes for the Local OpenLive session token.
///
/// SecRandomCopyBytes is Apple-only; Linux reads /dev/urandom. Both fail loudly rather than falling back to a
/// predictable generator: this token authenticates a loopback inference host.
public enum Random {
    public enum Failure: Error, CustomStringConvertible {
        case unavailable(String)

        public var description: String {
            switch self {
            case .unavailable(let why): "could not read cryptographically random bytes: \(why)"
            }
        }
    }

    public static func bytes(_ count: Int) throws -> [UInt8] {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw Failure.unavailable("SecRandomCopyBytes failed")
        }
        return bytes
        #else
        guard let handle = FileHandle(forReadingAtPath: "/dev/urandom") else {
            throw Failure.unavailable("/dev/urandom is not readable")
        }
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw Failure.unavailable("/dev/urandom did not return \(count) bytes")
        }
        return Array(data)
        #endif
    }
}
