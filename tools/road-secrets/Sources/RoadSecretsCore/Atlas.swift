import Foundation

/// What road-secrets reads from road-atlas (spec Section 3, item 8). Never written.
public struct Atlas: Equatable {
    public struct Database: Equatable {
        public let name: String
        public let status: String
    }

    public struct Env: Equatable {
        public let repo: String
        public let environment: String
        public let db: String
        public let schema: String
        public let connection: String
    }

    public var databases: [Database] = []
    public var envs: [Env] = []
    /// db name to ORDS host (scheme, no trailing slash), from `host` lines. "unknown" is dropped.
    public var hosts: [String: String] = [:]

    public init(databases: [Database] = [], envs: [Env] = [], hosts: [String: String] = [:]) {
        self.databases = databases
        self.envs = envs
        self.hosts = hosts
    }

    /// `$ROAD_ATLAS`, or else `~/Projects/road-atlas`.
    public static func locate(environment: [String: String], home: URL) -> URL {
        if let path = environment["ROAD_ATLAS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent("Projects/road-atlas")
    }

    /// Reads both files. Any failure is exit 6: every check that needs road-atlas fails closed.
    public static func load(root: URL) throws -> Atlas {
        do {
            let databases = try String(contentsOf: root.appendingPathComponent("databases.conf"), encoding: .utf8)
            let environments = try String(contentsOf: root.appendingPathComponent("environments.conf"), encoding: .utf8)
            return parse(databases: databases, environments: environments)
        } catch {
            throw RoadError(.refused,
                "refused: road-atlas cannot be read at \(root.path) (set ROAD_ATLAS). The production guard fails closed.")
        }
    }

    public static func parse(databases: String, environments: String) -> Atlas {
        var atlas = Atlas()
        for fields in records(databases) where fields.first == "db" && fields.count >= 4 {
            atlas.databases.append(Database(name: fields[1], status: fields[3]))
        }
        for fields in records(environments) {
            switch fields.first {
            case "env" where fields.count >= 6:
                atlas.envs.append(Env(repo: fields[1], environment: fields[2], db: fields[3],
                                      schema: fields[4], connection: fields[5]))
            case "host" where fields.count >= 3:
                if fields[2] != "unknown" && !fields[2].isEmpty {
                    var host = fields[2]
                    while host.hasSuffix("/") { host.removeLast() }
                    atlas.hosts[fields[1]] = host
                }
            default:
                break
            }
        }
        return atlas
    }

    static func records(_ text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            return line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    public func isActiveDatabase(_ name: String) -> Bool {
        databases.contains { $0.name == name && $0.status == "active" }
    }

    /// `<host>/ords` for the app's environment, if road-atlas records a host for its database.
    public func ordsBase(app: String, env: String) -> String? {
        guard let line = envs.first(where: { $0.repo == app && $0.environment == env }),
              let host = hosts[line.db] else { return nil }
        return "\(host)/ords"
    }

    var prodEnvs: [Env] { envs.filter { $0.environment == "prod" } }
}

/// The database name: the TNS name with its service suffix removed (spec Section 5.6).
/// A full connect descriptor is reduced through its service_name, dropping the domain and the
/// tenancy prefix, as in `geb0..._roadkitdb_medium.adb.oraclecloud.com` to `roadkitdb`.
public func databaseName(fromConnectString connect: String) -> String? {
    var name = connect.trimmingCharacters(in: .whitespaces).lowercased()
    if let range = name.range(of: "service_name=") {
        let tail = name[range.upperBound...]
        let value = tail.prefix { $0 != ")" && $0 != " " }
        let host = value.split(separator: ".").first.map(String.init) ?? ""
        let parts = host.split(separator: "_", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        name = String(parts[1])
    }
    if name.isEmpty || name.contains("(") || name.contains("/") || name.contains(":") { return nil }
    for suffix in ["_tpurgent", "_medium", "_high", "_low", "_tp"] where name.hasSuffix(suffix) {
        return String(name.dropLast(suffix.count))
    }
    return nil
}

/// Spec Section 5.7. `db` and `connections` are known only for `db` keys.
public enum ProdGuard {
    public static func check(key: Key, db: String?, connections: [String], atlas: Atlas) throws {
        if key.env == "prod" {
            throw RoadError(.refused, "refused: \(key) is for environment prod")
        }
        guard key.kind == .db else { return }
        for line in atlas.prodEnvs {
            if key.isAdmin, let db, line.db == db {
                throw RoadError(.refused,
                    "refused: \(db) serves production (\(line.repo) prod), so its ADMIN password is never stored")
            }
            if line.schema.caseInsensitiveCompare(key.name) == .orderedSame {
                throw RoadError(.refused,
                    "refused: \(key.name) is the schema of \(line.repo) prod")
            }
            if let hit = connections.first(where: { $0.caseInsensitiveCompare(line.connection) == .orderedSame }) {
                throw RoadError(.refused,
                    "refused: connection \(hit) is the connection of \(line.repo) prod")
            }
        }
    }
}
