// Spike S1: dedicated keychain mechanics (spec section 12).
let buildTag = "rebuild-2"
// Uses a TEST keychain and TEST service names. Never prints a secret value:
// reads report the length and a SHA-256 prefix only.
import Foundation
import Security
import CryptoKit

let home = FileManager.default.homeDirectoryForCurrentUser.path
let keychainPath = "\(home)/Library/Keychains/road-spike.keychain-db"
let loginService = "road-secrets-spike/keychain-password"
let loginAccount = "road-spike"
let itemService = "road-secrets-spike/item"
let itemAccount = "spike-key"

func die(_ msg: String, _ status: OSStatus = 0, code: Int32 = 1) -> Never {
    var detail = ""
    if status != 0 {
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "?"
        detail = " (OSStatus \(status): \(text))"
    }
    FileHandle.standardError.write("s1-spike: \(msg)\(detail)\n".data(using: .utf8)!)
    if status == errSecInteractionNotAllowed || status == errSecNoAccessForItem { exit(4) }
    exit(code)
}

func fingerprint(_ d: Data) -> String {
    let h = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    return "len=\(d.count) sha256=\(h.prefix(12))"
}

func randomSecret() -> Data {
    var bytes = [UInt8](repeating: 0, count: 32)
    let s = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard s == errSecSuccess else { die("SecRandomCopyBytes failed", s) }
    // Hex so it is plain ASCII.
    return bytes.map { String(format: "%02x", $0) }.joined().data(using: .utf8)!
}

/// Access list naming only this binary.
func selfOnlyAccess(label: String) -> SecAccess {
    var app: SecTrustedApplication?
    var s = SecTrustedApplicationCreateFromPath(nil, &app)
    guard s == errSecSuccess, let app else { die("SecTrustedApplicationCreateFromPath", s) }
    var access: SecAccess?
    s = SecAccessCreate(label as CFString, [app] as CFArray, &access)
    guard s == errSecSuccess, let access else { die("SecAccessCreate", s) }
    return access
}

func openKeychain() -> SecKeychain {
    var kc: SecKeychain?
    let s = SecKeychainOpen(keychainPath, &kc)
    guard s == errSecSuccess, let kc else { die("SecKeychainOpen", s) }
    return kc
}

func loginKeychain() -> SecKeychain {
    var kc: SecKeychain?
    let s = SecKeychainCopyDomainDefault(.user, &kc)
    guard s == errSecSuccess, let kc else { die("SecKeychainCopyDomainDefault", s) }
    return kc
}

func baseQuery(_ service: String, _ account: String, _ kc: SecKeychain) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service,
     kSecAttrAccount as String: account,
     kSecMatchSearchList as String: [kc]]
}

func addItem(_ service: String, _ account: String, _ value: Data, in kc: SecKeychain) {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: service,
                            kSecAttrAccount as String: account,
                            kSecValueData as String: value,
                            kSecUseKeychain as String: kc,
                            kSecAttrAccess as String: selfOnlyAccess(label: service)]
    let s = SecItemAdd(q as CFDictionary, nil)
    guard s == errSecSuccess else { die("add \(service)", s) }
}

func readItem(_ service: String, _ account: String, in kc: SecKeychain) -> Data? {
    var q = baseQuery(service, account, kc)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    var out: CFTypeRef?
    let s = SecItemCopyMatching(q as CFDictionary, &out)
    if s == errSecItemNotFound { return nil }
    guard s == errSecSuccess, let d = out as? Data else { die("read \(service)", s) }
    return d
}

func updateItem(_ service: String, _ account: String, _ value: Data, in kc: SecKeychain) {
    let s = SecItemUpdate(baseQuery(service, account, kc) as CFDictionary,
                          [kSecValueData as String: value] as CFDictionary)
    guard s == errSecSuccess else { die("update \(service)", s) }
}

func deleteItem(_ service: String, _ account: String, in kc: SecKeychain) {
    let s = SecItemDelete(baseQuery(service, account, kc) as CFDictionary)
    guard s == errSecSuccess || s == errSecItemNotFound else { die("delete \(service)", s) }
}

func searchList() -> [SecKeychain] {
    var list: CFArray?
    let s = SecKeychainCopyDomainSearchList(.user, &list)
    guard s == errSecSuccess else { die("SecKeychainCopyDomainSearchList", s) }
    return (list as? [SecKeychain]) ?? []
}

func path(of kc: SecKeychain) -> String {
    var len: UInt32 = 1024
    var buf = [CChar](repeating: 0, count: 1024)
    _ = SecKeychainGetPath(kc, &len, &buf)
    return String(cString: buf)
}

func setSearchList(_ l: [SecKeychain]) {
    let s = SecKeychainSetDomainSearchList(.user, l as CFArray)
    guard s == errSecSuccess else { die("SecKeychainSetDomainSearchList", s) }
}

func unlock() -> SecKeychain {
    guard let pw = readItem(loginService, loginAccount, in: loginKeychain()) else {
        die("keychain password not found in login keychain")
    }
    let kc = openKeychain()
    let s = pw.withUnsafeBytes { p in
        SecKeychainUnlock(kc, UInt32(pw.count), p.baseAddress, true)
    }
    guard s == errSecSuccess else { die("SecKeychainUnlock", s) }
    return kc
}

let args = CommandLine.arguments.dropFirst()
SecKeychainSetUserInteractionAllowed(ProcessInfo.processInfo.environment["S1_ALLOW_UI"] == "1")

switch args.first ?? "" {
case "init":
    if FileManager.default.fileExists(atPath: keychainPath) { die("\(keychainPath) already exists") }
    let pw = randomSecret()
    addItem(loginService, loginAccount, pw, in: loginKeychain())
    print("stored keychain password in login keychain: \(fingerprint(pw))")
    var kc: SecKeychain?
    var s = pw.withUnsafeBytes { p in
        SecKeychainCreate(keychainPath, UInt32(pw.count), p.baseAddress, false, nil, &kc)
    }
    guard s == errSecSuccess, let kc else { die("SecKeychainCreate", s) }
    // Finding: on macOS 27 the new keychain is not usable for settings until unlocked explicitly.
    s = pw.withUnsafeBytes { p in SecKeychainUnlock(kc, UInt32(pw.count), p.baseAddress, true) }
    guard s == errSecSuccess else { die("SecKeychainUnlock after create", s) }
    var settings = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
                                       lockOnSleep: false, useLockInterval: false,
                                       lockInterval: UInt32(Int32.max))  // UInt32.max fails with -25293; INT_MAX matches security(1)
    s = SecKeychainSetSettings(kc, &settings)
    guard s == errSecSuccess else { die("SecKeychainSetSettings", s) }
    var l = searchList()
    if !l.contains(where: { path(of: $0) == keychainPath }) { l.append(kc); setSearchList(l) }
    print("created \(keychainPath), never-lock, added to search list")
case "settings":
    let kc = ProcessInfo.processInfo.environment["S1_NO_UNLOCK"] == "1" ? openKeychain() : unlock()
    var st = SecKeychainSettings(version: UInt32(SEC_KEYCHAIN_SETTINGS_VERS1),
                                 lockOnSleep: true, useLockInterval: true, lockInterval: 0)
    let s = SecKeychainCopySettings(kc, &st)
    guard s == errSecSuccess else { die("SecKeychainCopySettings", s) }
    var status: SecKeychainStatus = 0
    _ = SecKeychainGetStatus(kc, &status)
    let unlocked = (status & UInt32(kSecUnlockStateStatus)) != 0
    let inList = searchList().contains { path(of: $0) == keychainPath }
    print("lockOnSleep=\(st.lockOnSleep) useLockInterval=\(st.useLockInterval) unlocked=\(unlocked) inSearchList=\(inList)")
case "lock":
    let s = SecKeychainLock(openKeychain())
    guard s == errSecSuccess else { die("SecKeychainLock", s) }
    print("locked")
case "unlock":
    _ = unlock(); print("unlocked with password from login keychain")
case "add":
    let v = randomSecret(); addItem(itemService, itemAccount, v, in: unlock())
    print("added item: \(fingerprint(v))")
case "read":
    guard let d = readItem(itemService, itemAccount, in: unlock()) else { die("item not found", code: 3) }
    print("read item: \(fingerprint(d))")
case "update":
    let v = randomSecret(); updateItem(itemService, itemAccount, v, in: unlock())
    print("updated item: \(fingerprint(v))")
case "delete":
    deleteItem(itemService, itemAccount, in: unlock()); print("deleted item")
case "destroy":
    let l = searchList().filter { path(of: $0) != keychainPath }
    setSearchList(l)
    if FileManager.default.fileExists(atPath: keychainPath) {
        let s = SecKeychainDelete(openKeychain())
        guard s == errSecSuccess else { die("SecKeychainDelete", s) }
    }
    deleteItem(loginService, loginAccount, in: loginKeychain())
    print("removed test keychain, search-list entry and login item")
default:
    die("usage: s1-spike init|settings|lock|unlock|add|read|update|delete|destroy", code: 2)
}
