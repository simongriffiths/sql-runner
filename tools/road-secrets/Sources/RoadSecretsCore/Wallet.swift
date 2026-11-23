import Foundation

/// A database wallet: a zip, or a directory that is zipped for the run (spec Section 8.1).
public final class WalletZip {
    public let path: String
    private let temporaryDirectory: URL?

    private init(path: String, temporaryDirectory: URL?) {
        self.path = path
        self.temporaryDirectory = temporaryDirectory
    }

    deinit { remove() }

    /// Removes a zip made for this run. A zip the user supplied is never touched.
    public func remove() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    static let excluded: Set<String> = ["credentials.sso", "dbtools.properties"]

    public static func isZip(_ wallet: String) -> Bool { wallet.lowercased().hasSuffix(".zip") }

    public static func exists(_ wallet: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: wallet, isDirectory: &isDirectory) else { return false }
        return isZip(wallet) ? !isDirectory.boolValue : isDirectory.boolValue
    }

    /// The zip to pass to `-cloudconfig`. A directory is zipped into a new private temporary
    /// directory (0700, file 0600), deleted when this object goes away.
    public static func prepare(_ wallet: String, runner: ProcessRunning) throws -> WalletZip {
        guard exists(wallet) else { throw RoadError(.usage, "wallet not found: \(wallet)") }
        if isZip(wallet) { return WalletZip(path: wallet, temporaryDirectory: nil) }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("road-secrets-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let holder = WalletZip(path: dir.appendingPathComponent("wallet.zip").path, temporaryDirectory: dir)
        let files = try fm.contentsOfDirectory(atPath: wallet).sorted().filter { name in
            var isDirectory: ObjCBool = false
            fm.fileExists(atPath: "\(wallet)/\(name)", isDirectory: &isDirectory)
            // A SQLcl connection folder also holds that connection's saved credentials. They are
            // not part of the wallet and must not be copied.
            return !isDirectory.boolValue && !excluded.contains(name)
        }
        let result = try runner.run("/usr/bin/zip", ["-q", "-j", holder.path] + files.map { "\(wallet)/\($0)" },
                                    stdin: "", environment: nil, directory: nil)
        guard result.status == 0 else {
            throw RoadError(.external, "could not zip the wallet directory \(wallet): \(result.output)")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: holder.path)
        return holder
    }

    /// The wallet's tnsnames.ora.
    public static func tnsnames(_ wallet: String, runner: ProcessRunning) throws -> String {
        if isZip(wallet) {
            let result = try runner.run("/usr/bin/unzip", ["-p", wallet, "tnsnames.ora"], stdin: "",
                                        environment: nil, directory: nil)
            guard result.status == 0 else { throw RoadError(.usage, "no tnsnames.ora in \(wallet)") }
            return result.output
        }
        do {
            return try String(contentsOfFile: "\(wallet)/tnsnames.ora", encoding: .utf8)
        } catch {
            throw RoadError(.usage, "no tnsnames.ora in \(wallet)")
        }
    }

    /// True if `tnsnames` defines the alias `tns`, ignoring case.
    public static func defines(_ tnsnames: String, alias tns: String) -> Bool {
        let alias = tns.lowercased()
        return tnsnames.split(whereSeparator: \.isNewline).contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix(alias) else { return false }
            let rest = line.dropFirst(alias.count).trimmingCharacters(in: .whitespaces)
            return rest.hasPrefix("=")
        }
    }
}
