import Foundation

public struct SQLclResult {
    /// Output with every known secret replaced by `********`. Safe to show.
    public let output: String
    public let status: Int32
    /// Lines that mark a failure (Section 8).
    public let failures: [String]
    /// Every `show user` answer, in order. "" when not connected.
    public let users: [String]

    public var ok: Bool { status == 0 && failures.isEmpty }
}

/// Drives SQLcl through standard input (spec Section 8).
public struct SQLcl {
    public static let prefix = "set echo off\nset feedback on\nset define off\n"

    let runner: ProcessRunning
    let executable: String
    let environment: [String: String]

    public init(runner: ProcessRunning, environment: [String: String]) throws {
        self.runner = runner
        var env = environment
        // Section 8.1: never TNS_ADMIN. Each connect names its wallet with -cloudconfig.
        env.removeValue(forKey: "TNS_ADMIN")
        self.environment = env
        if let bin = environment["SQLCL_BIN"], !bin.isEmpty {
            executable = bin
        } else if let found = which("sql", path: environment["PATH"]) {
            executable = found
        } else {
            throw RoadError(.external, "SQLcl not found: set SQLCL_BIN or put sql on PATH")
        }
    }

    /// Runs one SQLcl session. `secrets` are masked in everything returned.
    public func run(_ body: String, secrets: [String]) throws -> SQLclResult {
        let script = Self.prefix + body + "\nexit\n"
        let result = try runner.run(executable, ["-S", "/nolog"], stdin: script,
                                    environment: environment, directory: URL(fileURLWithPath: NSTemporaryDirectory()))
        let clean = scrub(stripANSI(result.output), secrets: secrets)
        return SQLclResult(output: clean, status: result.status,
                           failures: Self.failureLines(clean), users: Self.showUsers(clean))
    }

    static func failureLines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("ORA-") || t.hasPrefix("SP2-") || t.contains("Error Message = ORA-")
                || t.hasPrefix("Connection failed") || t.contains("already exists")
                || t.hasPrefix("Undefined connection") || t.hasPrefix("Unknown connection")
        }
    }

    static func showUsers(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("USER is \"") , t.hasSuffix("\"") else { return nil }
            return String(t.dropFirst("USER is \"".count).dropLast())
        }
    }

    /// A SQL or SQLcl string literal in double quotes. Passwords never contain `"` (Section 6.3).
    static func quoted(_ password: String) -> String { "\"\(password)\"" }

    /// `conn -cloudconfig <zip> <login>/"<password>"@<tns>` (Section 8.1).
    public static func connect(zip: String, login: String, password: String, tns: String) -> String {
        "conn -cloudconfig \(zip) \(login)/\(quoted(password))@\(tns)\nshow user"
    }

    /// `conn -cloudconfig <zip> -save <name> -savepwd -replace <login>/"<password>"@<tns>`.
    public static func resave(zip: String, name: String, login: String, password: String, tns: String) -> String {
        "conn -cloudconfig \(zip) -save \(name) -savepwd -replace \(login)/\(quoted(password))@\(tns)\nshow user"
    }

    public static func alterUser(_ name: String, password: String, replacing old: String?) -> String {
        if let old {
            return "alter user \(name) identified by \(quoted(password)) replace \(quoted(old));"
        }
        return "alter user \(name) identified by \(quoted(password));"
    }

    /// Runs several items in one session, each preceded by a marker line, and splits the output
    /// back into one result per item id. Used for re-saving and testing many connections at once.
    public func runEach(_ items: [(id: String, body: String)], secrets: [String]) throws -> [String: SQLclResult] {
        if items.isEmpty { return [:] }
        let marker = "ROAD_SECRETS_ITEM "
        let body = items.map { "prompt \(marker)\($0.id)\n\($0.body)" }.joined(separator: "\n")
        let whole = try run(body, secrets: secrets)
        var chunks: [String: [String]] = [:]
        var current: String?
        for raw in whole.output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix(marker) {
                current = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                chunks[current!] = []
            } else if let current {
                chunks[current]?.append(line)
            }
        }
        var results: [String: SQLclResult] = [:]
        for item in items {
            let text = (chunks[item.id] ?? []).joined(separator: "\n")
            // An item with no output at all never ran: count it as failed.
            let failures = Self.failureLines(text) + (chunks[item.id] == nil ? ["no output"] : [])
            results[item.id] = SQLclResult(output: text, status: whole.status, failures: failures,
                                           users: Self.showUsers(text))
        }
        return results
    }

    // MARK: Discovery (Section 8.2)

    public func discover() throws -> [SavedConnection] {
        let list = try run("connmgr list -flat", secrets: [])
        guard list.ok else {
            throw RoadError(.external, "connmgr list failed:\n\(list.output)")
        }
        let names = Connmgr.parseListFlat(list.output)
        if names.isEmpty { return [] }
        let show = try run(names.map { "connmgr show \($0)" }.joined(separator: "\n"), secrets: [])
        guard show.status == 0 else {
            throw RoadError(.external, "connmgr show failed:\n\(show.output)")
        }
        return Connmgr.parseShow(show.output)
    }

    public func show(_ name: String) throws -> SavedConnection {
        let result = try run("connmgr show \(name)", secrets: [])
        guard result.ok, let connection = Connmgr.parseShow(result.output).first(where: { $0.name == name }) else {
            throw RoadError(.usage, "no SQLcl saved connection named \(name)")
        }
        return connection
    }

    /// `connmgr test` for each connection in one session. Returns the names that failed.
    public func test(_ names: [String]) throws -> [String] {
        let results = try runEach(names.map { (id: $0, body: "connmgr test \($0)") }, secrets: [])
        return names.filter { name in
            guard let r = results[name] else { return true }
            return !r.failures.isEmpty || !r.output.contains("Connection Test Successful")
        }
    }
}
