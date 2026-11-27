import Foundation

/// Exit codes, spec Section 7.11.
public enum ExitCode: Int32 {
    case success = 0
    case usage = 2
    case notFound = 3
    case keychain = 4
    case external = 5
    case refused = 6
}

/// Every failure the tool reports. The message is printed after "road-secrets: ".
/// A message must never contain a password: build it from names, never from values.
public struct RoadError: Error, Equatable, CustomStringConvertible {
    public let code: ExitCode
    public let message: String

    public init(_ code: ExitCode, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    public static let keychainUnavailable = RoadError(
        .keychain,
        "the Keychain is not available in this session. Run from the desktop session on this Mac.")
}
