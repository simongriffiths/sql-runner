import Foundation

/// One saved SQLcl connection, as `connmgr show` describes it.
public struct SavedConnection: Equatable {
    public let name: String
    /// As stored, often lowercase: `livehub_deploy[av_acc]`.
    public let user: String
    public let connectString: String

    public init(name: String, user: String, connectString: String) {
        self.name = name
        self.user = user
        self.connectString = connectString
    }

    /// The part before any `[`: the database user that actually logs in.
    public var loginUser: String {
        String(user.split(separator: "[", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// The proxy schema inside `[...]`, if any.
    public var proxySchema: String? {
        guard let open = user.firstIndex(of: "["), let close = user.lastIndex(of: "]"), open < close else { return nil }
        return String(user[user.index(after: open)..<close])
    }

    /// The user `show user` reports once connected: the proxy schema if there is one.
    public var sessionUser: String { (proxySchema ?? loginUser).uppercased() }

    public var databaseName: String? { RoadSecretsCore.databaseName(fromConnectString: connectString) }

    public func logsIn(as name: String) -> Bool {
        loginUser.caseInsensitiveCompare(name) == .orderedSame
    }
}

/// Parsers for `connmgr list -flat` and `connmgr show` (spec Section 8.2).
public enum Connmgr {
    public static func parseListFlat(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains(" "), !line.hasPrefix("ORA-"), !line.hasPrefix("SP2-") else { return nil }
            return line.hasPrefix("/") ? String(line.dropFirst()) : line
        }
    }

    public static func parseShow(_ output: String) -> [SavedConnection] {
        var result: [SavedConnection] = []
        var name: String?
        var user = ""
        var connect = ""
        func flush() {
            if let name { result.append(SavedConnection(name: name, user: user, connectString: connect)) }
            name = nil
            user = ""
            connect = ""
        }
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if let v = value(line, "Name:") {
                flush()
                name = v
            } else if let v = value(line, "User:") {
                user = v
            } else if let v = value(line, "Connect String:") {
                connect = v
            }
        }
        flush()
        return result
    }

    static func value(_ line: String, _ label: String) -> String? {
        guard line.hasPrefix(label) else { return nil }
        return line.dropFirst(label.count).trimmingCharacters(in: .whitespaces)
    }

    /// Every connection that logs in as `user` on database `db`, whatever its service or proxy
    /// schema (spec Section 7.4, step 4). User names are compared ignoring case.
    public static func matching(_ all: [SavedConnection], user: String, db: String) -> [SavedConnection] {
        all.filter { $0.logsIn(as: user) && $0.databaseName == db }
            .sorted { $0.name < $1.name }
    }
}
