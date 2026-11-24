import Foundation
import Security

/// One Keychain item's attributes. Never holds the password.
public struct ItemAttributes: Equatable {
    public let service: String
    public let account: String
    public let label: String
    public let comment: String
    public let generic: Data?
}

/// Where entries are kept. `LoginKeychain` in the tool; an in-memory store in tests.
public protocol SecretStore {
    func read(service: String, account: String) throws -> String?
    func attributes(service: String, account: String) throws -> ItemAttributes?
    /// Creates or replaces the item.
    func write(service: String, account: String, password: String, label: String, comment: String,
               generic: Data?) throws
    /// Deletes the item. Missing is not an error.
    func delete(service: String, account: String) throws
    /// Attributes of every item whose service starts with one of `prefixes`.
    func list(prefixes: [String]) throws -> [ItemAttributes]
}

/// Generic-password items in the user's login keychain (spec Section 9.1). Each item's access
/// list names only this binary, so its reads raise no prompt and other programs get one.
public struct LoginKeychain: SecretStore {
    public init() {}

    func keychain() throws -> SecKeychain {
        var keychain: SecKeychain?
        let status = SecKeychainCopyDomainDefault(.user, &keychain)
        guard status == errSecSuccess, let keychain else { throw Self.error(status, "open the login keychain") }
        return keychain
    }

    func query(_ service: String, _ account: String?) throws -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchSearchList as String: [try keychain()],
        ]
        if let account { q[kSecAttrAccount as String] = account }
        return q
    }

    public func read(service: String, account: String) throws -> String? {
        var q = try query(service, account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw Self.error(status, "read \(service)") }
        return String(decoding: data, as: UTF8.self)
    }

    public func attributes(service: String, account: String) throws -> ItemAttributes? {
        var q = try query(service, account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let dict = out as? [String: Any] else {
            throw Self.error(status, "read the attributes of \(service)")
        }
        return Self.attributes(dict)
    }

    public func write(service: String, account: String, password: String, label: String, comment: String,
                      generic: Data?) throws {
        var attrs: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrLabel as String: label,
            kSecAttrComment as String: comment,
        ]
        if let generic { attrs[kSecAttrGeneric as String] = generic }
        let existing = try attributes(service: service, account: account)
        if existing != nil {
            let status = SecItemUpdate(try query(service, account) as CFDictionary, attrs as CFDictionary)
            guard status == errSecSuccess else { throw Self.error(status, "update \(service)") }
            return
        }
        var add = attrs
        add[kSecClass as String] = kSecClassGenericPassword
        add[kSecAttrService as String] = service
        add[kSecAttrAccount as String] = account
        add[kSecUseKeychain as String] = try keychain()
        add[kSecAttrAccess as String] = try Self.selfOnlyAccess(label: label)
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.error(status, "add \(service)") }
    }

    public func delete(service: String, account: String) throws {
        let status = SecItemDelete(try query(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status, "delete \(service)") }
    }

    public func list(prefixes: [String]) throws -> [ItemAttributes] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchSearchList as String: [try keychain()],
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw Self.error(status, "list items") }
        return items.map(Self.attributes).filter { item in prefixes.contains { item.service.hasPrefix($0) } }
    }

    static func attributes(_ dict: [String: Any]) -> ItemAttributes {
        ItemAttributes(service: dict[kSecAttrService as String] as? String ?? "",
                       account: dict[kSecAttrAccount as String] as? String ?? "",
                       label: dict[kSecAttrLabel as String] as? String ?? "",
                       comment: dict[kSecAttrComment as String] as? String ?? "",
                       generic: dict[kSecAttrGeneric as String] as? Data)
    }

    /// An access list whose only trusted application is the running binary.
    static func selfOnlyAccess(label: String) throws -> SecAccess {
        var app: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &app)
        guard status == errSecSuccess, let app else { throw error(status, "identify this program") }
        var access: SecAccess?
        status = SecAccessCreate(label as CFString, [app] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw error(status, "create an access list") }
        return access
    }

    /// Section 9.3: a refusal without user interaction is exit 4 with the fixed message. Spike S1
    /// found that a refused access-list check reports errSecAuthFailed (-25293).
    static func error(_ status: OSStatus, _ action: String) -> RoadError {
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecNoAccessForItem {
            return .keychainUnavailable
        }
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "unknown error"
        return RoadError(.keychain, "Keychain error while trying to \(action): \(text) (\(status))")
    }
}

/// An in-memory store for tests and dry runs.
public final class MemoryStore: SecretStore {
    public struct Item {
        public var password: String
        public var attributes: ItemAttributes
    }

    public private(set) var items: [String: Item] = [:]
    public init() {}

    func id(_ service: String, _ account: String) -> String { "\(service)\u{0}\(account)" }

    public func read(service: String, account: String) throws -> String? { items[id(service, account)]?.password }

    public func attributes(service: String, account: String) throws -> ItemAttributes? {
        items[id(service, account)]?.attributes
    }

    public func write(service: String, account: String, password: String, label: String, comment: String,
                      generic: Data?) throws {
        items[id(service, account)] = Item(password: password, attributes: ItemAttributes(
            service: service, account: account, label: label, comment: comment, generic: generic))
    }

    public func delete(service: String, account: String) throws { items[id(service, account)] = nil }

    public func list(prefixes: [String]) throws -> [ItemAttributes] {
        items.values.map(\.attributes).filter { item in prefixes.contains { item.service.hasPrefix($0) } }
    }
}
