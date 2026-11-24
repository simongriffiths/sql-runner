import Foundation

/// JSON metadata stored in the generic attribute of each entry (spec Section 5.3).
public struct DbMeta: Codable, Equatable {
    public var set_at: String
    public var db: String
    public var sqlcl_connections: [String]
    /// A wallet zip, or a wallet directory (Section 8.1).
    public var wallet: String
    public var tns: String
    /// The saved connection named with --connection when the key was first set.
    public var connection: String?

    public init(set_at: String, db: String, sqlcl_connections: [String], wallet: String, tns: String,
                connection: String?) {
        self.set_at = set_at
        self.db = db
        self.sqlcl_connections = sqlcl_connections
        self.wallet = wallet
        self.tns = tns
        self.connection = connection
    }
}

public struct PrincipalMeta: Codable, Equatable {
    public var set_at: String
    public var project: String
    public var ords_url: String?

    public init(set_at: String, project: String, ords_url: String?) {
        self.set_at = set_at
        self.project = project
        self.ords_url = ords_url
    }
}

enum Meta {
    static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

public enum Clock {
    public static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
