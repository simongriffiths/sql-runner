import Foundation

public enum Kind: String, CaseIterable, Sendable {
    case db
    case principal
}

/// A key, `road/<app>/<env>/<kind>/<NAME>` (spec Section 5.1).
public struct Key: Equatable, Hashable, CustomStringConvertible, Sendable {
    public let app: String
    public let env: String
    public let kind: Kind
    public let name: String

    public static let servicePrefix = "road/"
    public static let previousPrefix = "road-previous/"

    public var description: String { "road/\(app)/\(env)/\(kind.rawValue)/\(name)" }
    /// Keychain service of the current entry (Section 5.2).
    public var service: String { "road/\(app)/\(env)/\(kind.rawValue)" }
    /// Keychain service of the previous value, kept while a change is in progress (Section 5.4).
    public var previousService: String { "road-previous/\(app)/\(env)/\(kind.rawValue)" }
    public var account: String { name }
    public var label: String { "\(app) \(env) \(kind.rawValue) \(name)" }
    public var isAdmin: Bool { kind == .db && name == "ADMIN" }

    public init(app: String, env: String, kind: Kind, name: String) {
        self.app = app
        self.env = env
        self.kind = kind
        self.name = name
    }

    /// Parses and validates a key. Any broken rule is exit 2, except environment `prod`, which is
    /// refused by the production guard with exit 6 (Section 5.7, checklist item 14).
    public static func parse(_ text: String) throws -> Key {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "road" else {
            throw RoadError(.usage, "invalid key '\(text)': expected road/<app>/<env>/<kind>/<NAME>")
        }
        let (app, env, kindText, name) = (parts[1], parts[2], parts[3], parts[4])
        guard isSegment(app) else {
            throw RoadError(.usage, "invalid key '\(text)': app must be lowercase letters, digits and hyphens")
        }
        guard isSegment(env) else {
            throw RoadError(.usage, "invalid key '\(text)': env must be lowercase letters, digits and hyphens")
        }
        guard let kind = Kind(rawValue: kindText) else {
            throw RoadError(.usage, "invalid key '\(text)': kind must be db or principal")
        }
        guard isName(name) else {
            throw RoadError(.usage,
                "invalid key '\(text)': NAME must be uppercase letters, digits and _ . @ $ # - (lowercase is rejected, not converted)")
        }
        if env == "prod" {
            throw RoadError(.refused, "refused: \(text) is for environment prod. Production passwords are never stored.")
        }
        return Key(app: app, env: env, kind: kind, name: name)
    }

    /// Rebuilds a key from a Keychain service and account, as `list` finds them.
    /// Returns nil for items that are not road-secrets entries.
    public static func from(service: String, account: String) -> (key: Key, previous: Bool)? {
        var rest = service
        var previous = false
        if rest.hasPrefix(previousPrefix) {
            previous = true
            rest.removeFirst(previousPrefix.count)
        } else if rest.hasPrefix(servicePrefix) {
            rest.removeFirst(servicePrefix.count)
        } else {
            return nil
        }
        guard let key = try? parse("road/\(rest)/\(account)") else { return nil }
        return (key, previous)
    }

    static func isSegment(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            ("a"..."z").contains(c) || ("0"..."9").contains(c) || c == "-"
        }
    }

    static func isName(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            ("A"..."Z").contains(c) || ("0"..."9").contains(c) || "_.@$#-".unicodeScalars.contains(c)
        }
    }
}
