import Foundation

/// Everything the commands touch outside themselves, so that tests can replace it.
public struct Dependencies {
    public var store: SecretStore
    public var runner: ProcessRunning
    public var terminal: Terminal
    public var login: LoginChecking
    public var generator: PasswordGenerator
    public var environment: [String: String]
    public var home: URL
    public var currentDirectory: URL
    public var now: () -> Date
    public var out: (String) -> Void
    public var err: (String) -> Void
    public var copyToClipboard: (String) -> Bool
    /// True if git ignores `config/local.env` in this project.
    public var isLocalEnvIgnored: (URL) -> Bool

    public init(store: SecretStore, runner: ProcessRunning, terminal: Terminal, login: LoginChecking,
                generator: PasswordGenerator, environment: [String: String], home: URL, currentDirectory: URL,
                now: @escaping () -> Date, out: @escaping (String) -> Void, err: @escaping (String) -> Void,
                copyToClipboard: @escaping (String) -> Bool, isLocalEnvIgnored: @escaping (URL) -> Bool) {
        self.store = store
        self.runner = runner
        self.terminal = terminal
        self.login = login
        self.generator = generator
        self.environment = environment
        self.home = home
        self.currentDirectory = currentDirectory
        self.now = now
        self.out = out
        self.err = err
        self.copyToClipboard = copyToClipboard
        self.isLocalEnvIgnored = isLocalEnvIgnored
    }

    /// git, run through the given runner. Arguments carry paths only.
    public static func gitIgnored(runner: ProcessRunning) -> (URL) -> Bool {
        { project in
            let r = try? runner.run("/usr/bin/git", ["-C", project.path, "check-ignore", "-q", "config/local.env"],
                                    stdin: "", environment: nil, directory: nil)
            return r?.status == 0
        }
    }
}

/// Parsed command line: positionals, flags and `--name value` options.
struct Arguments {
    var positionals: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]

    init(_ args: [String], flags allowedFlags: Set<String>, values allowedValues: Set<String>) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if allowedFlags.contains(name) {
                    flags.insert(name)
                } else if allowedValues.contains(name) {
                    guard i + 1 < args.count else { throw RoadError(.usage, "\(arg) needs a value") }
                    values[name] = args[i + 1]
                    i += 1
                } else {
                    throw RoadError(.usage, "unknown option \(arg)")
                }
            } else {
                positionals.append(arg)
            }
            i += 1
        }
    }
}

public final class App {
    let d: Dependencies

    public static let usage = """
        usage: road-secrets <command> [arguments]

          init                    check that the tool can use the login keychain
          list [prefix] [--all]   list keys; never shows passwords
          add --app <app> --env <env> --kind db|principal --name <NAME> [details]
                                  create a new entry and set its first password
          set <key>               generate a new password and apply it everywhere
          sync <key>              push the Keychain password into every copy
          get <key>               print the password
          copy <key>              put the password on the clipboard
          check <key>             prove the stored password works
          delete <key> [--yes]    remove the entry

        <key> is written exactly as list prints it: road/<app>/<env>/<db|principal>/<NAME>.

        add details for db:         --connection <name> --wallet <zip|dir> --tns <name>
                                    [--via-admin] [--yes]
                                    Without --via-admin, the current password is read from
                                    standard input, with no prompt and no echo.
        add details for principal:  [--project <path>] [--ords-url <url>]

        Optional on existing keys:  set --via-admin, set --yes (several connections),
                                    set/sync/check --project <path> (principal keys)
        The project folder defaults to the stored one, else $ROAD_PROJECTS/<app>,
        else ~/Projects/<app>.
        """

    public init(_ dependencies: Dependencies) {
        d = dependencies
    }

    /// Runs one command and returns the process exit code.
    public func main(_ args: [String]) -> Int32 {
        do {
            try dispatch(args)
            return ExitCode.success.rawValue
        } catch let error as RoadError {
            d.err("road-secrets: \(error.message)")
            return error.code.rawValue
        } catch {
            d.err("road-secrets: \(error.localizedDescription)")
            return ExitCode.external.rawValue
        }
    }

    func dispatch(_ args: [String]) throws {
        guard let command = args.first else { throw RoadError(.usage, App.usage) }
        let rest = Array(args.dropFirst())
        switch command {
        case "init":
            _ = try Arguments(rest, flags: [], values: [])
            try initCheck()
        case "list":
            let a = try Arguments(rest, flags: ["all"], values: [])
            guard a.positionals.count <= 1 else { throw RoadError(.usage, "list takes at most one prefix") }
            try list(prefix: a.positionals.first, all: a.flags.contains("all"))
        case "add":
            let a = try Arguments(rest, flags: ["via-admin", "yes"],
                                  values: ["app", "env", "kind", "name", "connection", "wallet", "tns",
                                           "project", "ords-url"])
            try add(a)
        case "set":
            let a = try Arguments(rest, flags: ["via-admin", "yes"], values: ["project"])
            let key = try oneKey(a)
            switch key.kind {
            case .db:
                guard a.values["project"] == nil else { throw RoadError(.usage, "--project is only for principal keys") }
                try setDb(key, viaAdmin: a.flags.contains("via-admin"), yes: a.flags.contains("yes"))
            case .principal:
                guard a.flags.isEmpty else { throw RoadError(.usage, "--via-admin and --yes are only for db keys") }
                try setPrincipal(key, projectOverride: a.values["project"])
            }
        case "sync":
            let a = try Arguments(rest, flags: [], values: ["project"])
            let key = try oneKey(a)
            switch key.kind {
            case .db:
                guard a.values["project"] == nil else { throw RoadError(.usage, "--project is only for principal keys") }
                try syncDb(key)
            case .principal: try syncPrincipal(key, projectOverride: a.values["project"])
            }
        case "get":
            let key = try oneKey(try Arguments(rest, flags: [], values: []))
            d.out(try password(key))
        case "copy":
            let key = try oneKey(try Arguments(rest, flags: [], values: []))
            guard d.copyToClipboard(try password(key)) else { throw RoadError(.external, "could not write to the clipboard") }
            d.err("copied \(key)")
        case "check":
            let a = try Arguments(rest, flags: [], values: ["project"])
            let key = try oneKey(a)
            switch key.kind {
            case .db:
                guard a.values["project"] == nil else { throw RoadError(.usage, "--project is only for principal keys") }
                try checkDb(key)
            case .principal: try checkPrincipal(key, projectOverride: a.values["project"])
            }
        case "delete":
            let a = try Arguments(rest, flags: ["yes"], values: [])
            try delete(try oneKey(a), yes: a.flags.contains("yes"))
        case "help", "-h", "--help":
            d.out(App.usage)
        default:
            throw RoadError(.usage, "unknown command \(command)\n\(App.usage)")
        }
    }

    func oneKey(_ a: Arguments) throws -> Key {
        guard a.positionals.count == 1 else {
            throw RoadError(.usage, "expected exactly one key, written as list prints it: road/<app>/<env>/<kind>/<NAME>")
        }
        return try Key.parse(a.positionals[0])
    }

    /// The entry's attributes, or exit 3 pointing to `add`.
    func existing(_ key: Key) throws -> ItemAttributes {
        guard let attributes = try d.store.attributes(service: key.service, account: key.account) else {
            throw RoadError(.notFound, "no entry for \(key). Create it with: road-secrets add --app \(key.app) --env \(key.env) --kind \(key.kind.rawValue) --name \(key.name) ...")
        }
        return attributes
    }

    // MARK: add

    /// `add`: builds the key from named parts, refuses an existing one, and does the first set.
    /// It never asks a question.
    func add(_ a: Arguments) throws {
        guard a.positionals.isEmpty else {
            throw RoadError(.usage, "add takes no key: give --app, --env, --kind and --name")
        }
        let missing = ["app", "env", "kind", "name"].filter { a.values[$0] == nil }.map { "--\($0)" }
        guard missing.isEmpty, let app = a.values["app"], let env = a.values["env"],
              let kindText = a.values["kind"], let name = a.values["name"] else {
            throw RoadError(.usage, "add needs \(missing.joined(separator: ", "))")
        }
        guard let kind = Kind(rawValue: kindText) else {
            throw RoadError(.usage, "--kind must be db or principal")
        }
        let key = try Key.parse("road/\(app)/\(env)/\(kind.rawValue)/\(name)")
        if try d.store.attributes(service: key.service, account: key.account) != nil {
            throw RoadError(.usage, "\(key) already exists. To change its password, run: road-secrets set \(key)")
        }
        switch kind {
        case .db:
            let wrong = ["project", "ords-url"].filter { a.values[$0] != nil }
            guard wrong.isEmpty else { throw RoadError(.usage, "--project and --ords-url are only for principal keys") }
            let atlas = try loadAtlas()
            let target = try resolveDb(key, a.values, atlas: atlas)
            var old: String?
            let viaAdmin = a.flags.contains("via-admin")
            if !viaAdmin {
                guard let typed = d.terminal.readStandardInputSecret() else {
                    throw RoadError(.usage,
                        "no current password on standard input for \(key.name). Pipe it in, or use --via-admin.")
                }
                old = typed
            }
            try changeDb(key, target: target, atlas: atlas, viaAdmin: viaAdmin, yes: a.flags.contains("yes"),
                         interactive: false, old: old, existing: nil)
        case .principal:
            let wrong = ["connection", "wallet", "tns"].filter { a.values[$0] != nil }
            guard wrong.isEmpty, a.flags.isEmpty else {
                throw RoadError(.usage, "--connection, --wallet, --tns, --via-admin and --yes are only for db keys")
            }
            let project = projectFor(key, override: a.values["project"], meta: nil)
            try changePrincipal(key, project: project, ords: a.values["ords-url"], existing: nil)
        }
        d.out(key.description)
    }

    // MARK: Store helpers

    func password(_ key: Key) throws -> String {
        guard let value = try d.store.read(service: key.service, account: key.account) else {
            throw RoadError(.notFound, "no entry for \(key)")
        }
        return value
    }

    func comment() -> String { "set \(Clock.day(d.now()))" }

    /// Copies the current value to the previous item (Section 5.4).
    func keepPrevious(_ key: Key, value: String, attributes: ItemAttributes) throws {
        try d.store.write(service: key.previousService, account: key.account, password: value,
                          label: "\(key.label) (previous)", comment: attributes.comment, generic: attributes.generic)
    }

    /// Puts the entry back as it was before `set` began (Section 7.3, step 8).
    func restore(_ key: Key, value: String?, attributes: ItemAttributes?) {
        if let value, let attributes {
            try? d.store.write(service: key.service, account: key.account, password: value,
                               label: attributes.label, comment: attributes.comment, generic: attributes.generic)
        } else {
            try? d.store.delete(service: key.service, account: key.account)
        }
        try? d.store.delete(service: key.previousService, account: key.account)
    }

    func loadAtlas() throws -> Atlas {
        try Atlas.load(root: Atlas.locate(environment: d.environment, home: d.home))
    }

    func sqlcl() throws -> SQLcl { try SQLcl(runner: d.runner, environment: d.environment) }

    // MARK: init, list, delete

    func initCheck() throws {
        let service = "road-secrets/init-check"
        let probe = d.generator.generate()
        try d.store.write(service: service, account: "road", password: probe, label: "road-secrets init check",
                          comment: "temporary", generic: nil)
        let back = try d.store.read(service: service, account: "road")
        try d.store.delete(service: service, account: "road")
        guard back == probe else { throw RoadError(.keychain, "the login keychain did not return what was written") }
        d.out("road-secrets: login keychain OK")
    }

    func list(prefix: String?, all: Bool) throws {
        let prefixes = [Key.servicePrefix] + (all ? [Key.previousPrefix] : [])
        let rows = try d.store.list(prefixes: prefixes).compactMap { item -> (Key, Bool, ItemAttributes)? in
            guard let parsed = Key.from(service: item.service, account: item.account) else { return nil }
            return (parsed.key, parsed.previous, item)
        }
        .filter { prefix == nil || $0.0.description.hasPrefix(prefix!) }
        .sorted { ($0.0.description, $0.1 ? 1 : 0) < ($1.0.description, $1.1 ? 1 : 0) }
        for (key, previous, item) in rows {
            let date = item.comment.hasPrefix("set ") ? String(item.comment.dropFirst(4)) : item.comment
            d.out("\(key)\t\(date)\t\(key.label)\(previous ? "\t(previous)" : "")")
        }
    }

    func delete(_ key: Key, yes: Bool) throws {
        let current = try d.store.attributes(service: key.service, account: key.account)
        let previous = try d.store.attributes(service: key.previousService, account: key.account)
        guard current != nil || previous != nil else { throw RoadError(.notFound, "no entry for \(key)") }
        if !yes {
            guard d.terminal.isInteractive else {
                throw RoadError(.usage, "standard input is not a terminal: pass --yes to delete \(key)")
            }
            guard d.terminal.confirm("Delete \(key)? This changes nothing in the database, SQLcl or config/local.env.") else {
                throw RoadError(.usage, "not deleted")
            }
        }
        try d.store.delete(service: key.service, account: key.account)
        try d.store.delete(service: key.previousService, account: key.account)
        d.out("deleted \(key)")
    }

    // MARK: db keys

    struct DbTarget {
        let meta: DbMeta?
        let connection: String
        let wallet: String
        let tns: String
        let db: String
    }

    /// Section 7.3, step 1.
    func resolveDb(_ key: Key, _ values: [String: String]?, atlas: Atlas) throws -> DbTarget {
        let existing = try d.store.attributes(service: key.service, account: key.account)
        let meta = Meta.decode(DbMeta.self, existing?.generic)
        let connection = values?["connection"] ?? meta?.connection ?? meta?.sqlcl_connections.first
        let wallet = values?["wallet"] ?? meta?.wallet
        let tns = values?["tns"] ?? meta?.tns
        let missing = [("--connection", connection), ("--wallet", wallet), ("--tns", tns)]
            .filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty, let connection, let wallet, let tns else {
            if values == nil {
                throw RoadError(.usage, "\(key) has no stored connection details. Delete it and add it again.")
            }
            throw RoadError(.usage, "add for a db key needs \(missing.joined(separator: ", "))")
        }
        guard WalletZip.exists(wallet) else { throw RoadError(.usage, "wallet not found: \(wallet)") }
        guard WalletZip.defines(try WalletZip.tnsnames(wallet, runner: d.runner), alias: tns) else {
            throw RoadError(.usage, "the wallet's tnsnames.ora does not define \(tns)")
        }
        guard let db = databaseName(fromConnectString: tns) else {
            throw RoadError(.usage, "cannot derive a database name from \(tns): expected a _high, _medium, _low, _tp or _tpurgent suffix")
        }
        guard atlas.isActiveDatabase(db) else {
            throw RoadError(.usage, "\(db) is not an active db line in road-atlas databases.conf")
        }
        return DbTarget(meta: meta, connection: connection, wallet: wallet, tns: tns, db: db)
    }

    /// Section 7.3, step 4. Applies the production guard to what it finds.
    func discover(_ key: Key, db: String, atlas: Atlas, sql: SQLcl) throws -> [SavedConnection] {
        let found = Connmgr.matching(try sql.discover(), user: key.name, db: db)
        try ProdGuard.check(key: key, db: db, connections: found.map(\.name), atlas: atlas)
        return found
    }

    /// `set` for an existing db key: everything comes from the entry.
    func setDb(_ key: Key, viaAdmin: Bool, yes: Bool) throws {
        let attributes = try existing(key)
        let atlas = try loadAtlas()
        let target = try resolveDb(key, nil, atlas: atlas)
        let old = viaAdmin ? nil : try password(key)
        try changeDb(key, target: target, atlas: atlas, viaAdmin: viaAdmin, yes: yes,
                     interactive: d.terminal.isInteractive, old: old, existing: attributes)
    }

    /// Section 7.3, steps 2 to 10. `old` is the current password, unless `viaAdmin`.
    /// `existing` is the current entry, or nil when `add` creates it.
    func changeDb(_ key: Key, target: DbTarget, atlas: Atlas, viaAdmin: Bool, yes: Bool, interactive: Bool,
                  old: String?, existing: ItemAttributes?) throws {
        let sql = try sqlcl()

        // Step 2.
        let named = try sql.show(target.connection)
        guard named.logsIn(as: key.name) else {
            throw RoadError(.usage, "connection \(target.connection) logs in as \(named.loginUser), not \(key.name)")
        }

        // Step 3.
        if key.isAdmin {
            guard key.app == target.db else {
                throw RoadError(.usage, "an ADMIN key must use the database name as its app: --app \(target.db)")
            }
            guard !viaAdmin else { throw RoadError(.usage, "--via-admin cannot be used on the ADMIN entry itself") }
        }
        try ProdGuard.check(key: key, db: target.db, connections: [target.connection], atlas: atlas)

        // Step 4.
        let found = try discover(key, db: target.db, atlas: atlas, sql: sql)
        d.err("\(found.count) saved connection(s) log in as \(key.name) on \(target.db): \(found.map(\.name).joined(separator: ", "))")
        if found.count > 1 && !yes {
            guard interactive else {
                throw RoadError(.usage, "\(found.count) connections would be re-saved: pass --yes")
            }
            guard d.terminal.confirm("Change the password and re-save all \(found.count)?") else {
                throw RoadError(.usage, "nothing changed")
            }
        }

        // Step 5: ADMIN, when asked for.
        let current = existing == nil ? nil : try d.store.read(service: key.service, account: key.account)
        let admin = viaAdmin ? try adminEntry(db: target.db) : nil
        guard viaAdmin || old != nil else { throw RoadError(.usage, "no current password for \(key.name)") }

        let zip = try WalletZip.prepare(target.wallet, runner: d.runner)
        defer { zip.remove() }
        let adminZip = try admin.map { try WalletZip.prepare($0.meta.wallet, runner: d.runner) }
        defer { adminZip?.remove() }

        // Step 6: store the new value first.
        let new = d.generator.generate(avoiding: [key.name])
        if let current, let existing { try keepPrevious(key, value: current, attributes: existing) }
        let meta = DbMeta(set_at: Clock.iso8601(d.now()), db: target.db, sqlcl_connections: found.map(\.name),
                          wallet: target.wallet, tns: target.tns, connection: target.connection)
        try d.store.write(service: key.service, account: key.account, password: new, label: key.label,
                          comment: comment(), generic: Meta.encode(meta))
        let secrets = [new, old, admin?.password].compactMap { $0 }

        // Step 7. The self-change logs in directly as NAME with the old password, not through the
        // saved connection: a proxy connection would log in as its proxy schema instead.
        let body: String
        let expected: String
        if let admin, let adminZip {
            body = SQLcl.connect(zip: adminZip.path, login: "ADMIN", password: admin.password, tns: admin.meta.tns)
                + "\n" + SQLcl.alterUser(key.name, password: new, replacing: nil)
            expected = "ADMIN"
        } else {
            body = SQLcl.connect(zip: zip.path, login: key.name, password: old!, tns: target.tns)
                + "\n" + SQLcl.alterUser(key.name, password: new, replacing: old)
            expected = key.name
        }
        let result = try sql.run(body, secrets: secrets)
        guard result.ok, result.users.first?.uppercased() == expected else {
            // Step 8.
            restore(key, value: current, attributes: existing)
            throw RoadError(.external, "the password was not changed. SQLcl said:\n\(result.output)")
        }
        try d.store.delete(service: key.previousService, account: key.account)

        // Step 9.
        let failed = try resave(found, password: new, zip: zip.path, sql: sql, secrets: secrets)
        if !failed.isEmpty {
            throw RoadError(.external,
                "the database and the Keychain have the new password, but these connections were not re-saved: \(failed.joined(separator: ", ")). Run: road-secrets sync \(key)")
        }

        // Step 10.
        d.err("road-secrets: set \(key). Re-saved \(found.count) connection(s).")
    }

    /// The single ADMIN entry for a database (Section 5.5).
    func adminEntry(db: String) throws -> (password: String, meta: DbMeta) {
        let entries = try d.store.list(prefixes: ["road/\(db)/"]).filter {
            $0.account == "ADMIN" && $0.service.hasSuffix("/db")
        }
        guard entries.count == 1, let entry = entries.first,
              let meta = Meta.decode(DbMeta.self, entry.generic),
              let value = try d.store.read(service: entry.service, account: entry.account) else {
            throw RoadError(.usage,
                "no ADMIN entry for \(db). Adopt road/\(db)/<env>/db/ADMIN first, unless \(db) serves production, in which case it has none.")
        }
        return (value, meta)
    }

    /// Re-saves each connection with `-cloudconfig ... -replace`, then runs `connmgr test` on the
    /// ones that saved (Section 8.1). Returns the names that failed either step.
    func resave(_ connections: [SavedConnection], password: String, zip: String, sql: SQLcl,
                secrets: [String]) throws -> [String] {
        var failed: [String] = []
        var items: [(id: String, body: String)] = []
        for c in connections {
            guard !c.connectString.contains("("), !c.connectString.isEmpty else {
                d.err("cannot re-save \(c.name): its connect string is not a TNS name")
                failed.append(c.name)
                continue
            }
            items.append((c.name, SQLcl.resave(zip: zip, name: c.name, login: c.user, password: password,
                                               tns: c.connectString)))
        }
        let results = try sql.runEach(items, secrets: secrets)
        var saved: [String] = []
        for c in connections where !failed.contains(c.name) {
            guard let r = results[c.name], r.failures.isEmpty,
                  r.users.first?.uppercased() == c.sessionUser else {
                d.err("re-save failed for \(c.name):\n\(results[c.name]?.output ?? "")")
                failed.append(c.name)
                continue
            }
            saved.append(c.name)
        }
        let untested = try sql.test(saved)
        for name in untested { d.err("connmgr test failed for \(name)") }
        return failed + untested
    }

    func syncDb(_ key: Key) throws {
        _ = try existing(key)
        let value = try password(key)
        let atlas = try loadAtlas()
        let target = try resolveDb(key, nil, atlas: atlas)
        let sql = try sqlcl()
        let found = try discover(key, db: target.db, atlas: atlas, sql: sql)
        let zip = try WalletZip.prepare(target.wallet, runner: d.runner)
        defer { zip.remove() }
        let failed = try resave(found, password: value, zip: zip.path, sql: sql, secrets: [value])
        if var meta = target.meta, let attrs = try d.store.attributes(service: key.service, account: key.account) {
            meta.sqlcl_connections = found.map(\.name)
            try d.store.write(service: key.service, account: key.account, password: value, label: attrs.label,
                              comment: attrs.comment, generic: Meta.encode(meta))
        }
        guard failed.isEmpty else {
            throw RoadError(.external, "\(failed.count) of \(found.count) connection(s) failed: \(failed.joined(separator: ", "))")
        }
        d.out("road-secrets: synced \(key) to \(found.count) connection(s); connmgr test passed for all")
    }

    func checkDb(_ key: Key) throws {
        _ = try existing(key)
        let value = try password(key)
        let atlas = try loadAtlas()
        let target = try resolveDb(key, nil, atlas: atlas)
        let sql = try sqlcl()
        let zip = try WalletZip.prepare(target.wallet, runner: d.runner)
        defer { zip.remove() }
        var problems: [String] = []

        let direct = try sql.run(SQLcl.connect(zip: zip.path, login: key.name, password: value, tns: target.tns)
                                 + "\nselect 1 from dual;", secrets: [value])
        if direct.ok && direct.users.first?.uppercased() == key.name {
            d.out("ok: the Keychain password logs in as \(key.name) on \(target.tns)")
        } else {
            d.out("FAILED: the Keychain password does not log in as \(key.name) on \(target.tns)\n\(direct.output)")
            problems.append("Keychain password")
        }

        let found = try discover(key, db: target.db, atlas: atlas, sql: sql)
        let failed = try sql.test(found.map(\.name))
        d.out("\(found.count - failed.count) of \(found.count) saved connection(s) pass connmgr test")
        for name in failed { d.out("FAILED: \(name)") }
        if !failed.isEmpty { problems.append("\(failed.count) connection(s)") }
        guard problems.isEmpty else { throw RoadError(.external, "check failed: \(problems.joined(separator: ", "))") }
    }

    // MARK: principal keys

    /// The project folder for a principal key: `--project`, else the stored one, else
    /// `$ROAD_PROJECTS/<app>`, else `~/Projects/<app>`. Works from any folder.
    func projectFor(_ key: Key, override: String?, meta: PrincipalMeta?) -> URL {
        if let override { return URL(fileURLWithPath: override).standardizedFileURL }
        if let stored = meta?.project { return URL(fileURLWithPath: stored) }
        if let base = d.environment["ROAD_PROJECTS"], !base.isEmpty {
            return URL(fileURLWithPath: base).appendingPathComponent(key.app)
        }
        return d.home.appendingPathComponent("Projects").appendingPathComponent(key.app)
    }

    /// `set` for an existing principal key.
    func setPrincipal(_ key: Key, projectOverride: String?) throws {
        let attributes = try existing(key)
        let meta = Meta.decode(PrincipalMeta.self, attributes.generic)
        try changePrincipal(key, project: projectFor(key, override: projectOverride, meta: meta),
                            ords: meta?.ords_url, existing: attributes)
    }

    /// Section 7.4. `existing` is the current entry, or nil when `add` creates it.
    func changePrincipal(_ key: Key, project: URL, ords givenOrds: String?, existing: ItemAttributes?) throws {
        // Step 1.
        guard project.lastPathComponent == key.app else {
            throw RoadError(.usage, "the project \(project.path) is not \(key.app)")
        }
        let script = project.appendingPathComponent("bin/set-principal-password.sh")
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw RoadError(.usage, "\(script.path) not found. Give --project if the app is somewhere else.")
        }

        // Step 2: Key.parse already refuses env prod.
        try ProdGuard.check(key: key, db: nil, connections: [], atlas: Atlas())
        let ords = givenOrds ?? (try? loadAtlas())?.ordsBase(app: key.app, env: key.env)

        // Step 3.
        d.err("warning: every live session for principal \(key.name) in \(key.app) \(key.env) will end.")

        // Step 4.
        let current = existing == nil ? nil : try d.store.read(service: key.service, account: key.account)
        if let current, let existing { try keepPrevious(key, value: current, attributes: existing) }
        let new = d.generator.generate(avoiding: [key.name])
        let newMeta = PrincipalMeta(set_at: Clock.iso8601(d.now()), project: project.path, ords_url: ords)
        try d.store.write(service: key.service, account: key.account, password: new, label: key.label,
                          comment: comment(), generic: Meta.encode(newMeta))

        // Step 5: the password goes in twice on standard input, never as an argument.
        let result = try d.runner.run(script.path, ["--env", key.env, "--subject", key.name],
                                      stdin: "\(new)\n\(new)\n", environment: d.environment, directory: project)
        guard result.status == 0 else {
            // Step 6.
            restore(key, value: current, attributes: existing)
            throw RoadError(.external,
                "set-principal-password.sh failed (exit \(result.status)); nothing changed:\n\(scrub(result.output, secrets: [new]))")
        }
        try d.store.delete(service: key.previousService, account: key.account)

        // Step 7.
        let note = try updateLocalEnv(key, project: project, password: new)

        // Step 8.
        d.err("road-secrets: set \(key). \(note)")
    }

    /// Section 7.11. Returns a one-line description of what happened.
    func updateLocalEnv(_ key: Key, project: URL, password: String) throws -> String {
        let outcome: LocalEnv.Outcome
        do {
            outcome = try LocalEnv.update(project: project, name: key.name, password: password,
                                          isIgnored: d.isLocalEnvIgnored)
        } catch let error as RoadError {
            throw RoadError(.external,
                "the principal and the Keychain have the new password, but config/local.env was not updated: \(error.message) Then run: road-secrets sync \(key)")
        }
        switch outcome {
        case .missing:
            return "No config/local.env: copy config/local.env.example and run road-secrets sync \(key) (road-atlas D-03)."
        case .otherPrincipal(let other):
            return "config/local.env names \(other), so it was not changed."
        case .updated:
            return "config/local.env updated."
        }
    }

    func syncPrincipal(_ key: Key, projectOverride: String?) throws {
        let attributes = try existing(key)
        let value = try password(key)
        let project = projectFor(key, override: projectOverride,
                                 meta: Meta.decode(PrincipalMeta.self, attributes.generic))
        d.out("road-secrets: \(try updateLocalEnv(key, project: project, password: value))")
    }

    func checkPrincipal(_ key: Key, projectOverride: String?) throws {
        let attributes = try existing(key)
        let value = try password(key)
        let meta = Meta.decode(PrincipalMeta.self, attributes.generic)
        let projectPath = projectFor(key, override: projectOverride, meta: meta).path
        var problems: [String] = []

        // 1. The login endpoint.
        if let base = meta?.ords_url {
            let project = projectPath
            let config = (try? String(contentsOfFile: "\(project)/road.config", encoding: .utf8)) ?? ""
            guard let apiBase = LocalEnv.value(of: "API_BASE_PATH", in: config), !apiBase.isEmpty else {
                throw RoadError(.external, "API_BASE_PATH not found in \(project)/road.config")
            }
            var trimmed = base
            while trimmed.hasSuffix("/") { trimmed.removeLast() }
            guard let url = URL(string: "\(trimmed)/\(apiBase)/jwt-auth/login") else {
                throw RoadError(.usage, "invalid ORDS URL \(base)")
            }
            let (status, body) = try d.login.login(url: url, username: key.name, password: value)
            let token = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["access_token"] as? String
            switch status {
            case 200 where !(token ?? "").isEmpty:
                d.out("ok: scaffold login as \(key.name) at \(url.absoluteString)")
            case 404:
                d.out("FAILED: \(url.absoluteString) returned 404: the scaffold login is not deployed (the app may use external OIDC)")
                problems.append("login endpoint")
            default:
                d.out("FAILED: scaffold login returned HTTP \(status)")
                problems.append("login")
            }
        } else {
            d.out("skipped: no ORDS URL stored for this key")
        }

        // 2. config/local.env.
        do {
            let file = "\(projectPath)/config/local.env"
            if let text = try? String(contentsOfFile: file, encoding: .utf8), LocalEnv.testPrincipal(text) == key.name {
                if LocalEnv.value(of: "ROAD_TEST_PASSWORD", in: text) == value {
                    d.out("ok: config/local.env matches the Keychain")
                } else {
                    d.out("FAILED: config/local.env does not match the Keychain. Run: road-secrets sync \(key)")
                    problems.append("config/local.env")
                }
            }
        }
        guard problems.isEmpty else { throw RoadError(.external, "check failed: \(problems.joined(separator: ", "))") }
    }
}
