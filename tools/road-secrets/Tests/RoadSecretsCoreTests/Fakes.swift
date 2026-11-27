import Foundation
@testable import RoadSecretsCore

/// A fake SQLcl that reads the script line by line, plus handlers for other programs.
final class FakeRunner: ProcessRunning {
    struct Call {
        let executable: String
        let arguments: [String]
        let stdin: String
    }

    var calls: [Call] = []
    /// Saved connections SQLcl knows about.
    var connections: [SavedConnection] = []
    /// Passwords the fake database accepts, by user (uppercase).
    var passwords: [String: String] = [:]
    /// Connections whose re-save should fail.
    var failSaving: Set<String> = []
    /// Exit status of set-principal-password.sh.
    var principalScriptStatus: Int32 = 0

    func run(_ executable: String, _ arguments: [String], stdin: String,
             environment: [String: String]?, directory: URL?) throws -> ProcessResult {
        calls.append(Call(executable: executable, arguments: arguments, stdin: stdin))
        if executable.hasSuffix("/sql") { return ProcessResult(status: 0, output: sqlcl(stdin)) }
        if executable.hasSuffix("set-principal-password.sh") {
            return ProcessResult(status: principalScriptStatus, output: "[INFO] SUCCESS")
        }
        if executable == "/usr/bin/zip" {
            FileManager.default.createFile(atPath: arguments[2], contents: Data("zip".utf8))
            return ProcessResult(status: 0, output: "")
        }
        return ProcessResult(status: 1, output: "unexpected \(executable)")
    }

    var sqlScripts: [String] { calls.filter { $0.executable.hasSuffix("/sql") }.map(\.stdin) }

    func sqlcl(_ script: String) -> String {
        var out: [String] = []
        var user = ""
        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.split(separator: " ").map(String.init)
            if line.hasPrefix("prompt ") {
                out.append(String(line.dropFirst(7)))
            } else if line == "connmgr list -flat" {
                out += connections.map { "/" + $0.name }
            } else if line.hasPrefix("connmgr show ") {
                let name = words[2]
                if let c = connections.first(where: { $0.name == name }) {
                    out += ["Name: \(c.name)", "Connect String: \(c.connectString)", "User: \(c.user)", "Password: ******"]
                } else {
                    out.append("Unknown connection \(name)")
                }
            } else if line.hasPrefix("connmgr test ") {
                out.append(connections.contains { $0.name == words[2] } ? "Connection Test Successful" : "Undefined connection \(words[2])")
            } else if line.hasPrefix("conn ") {
                // conn -cloudconfig <zip> [-save <name> -savepwd -replace] login/"pw"@tns
                let credential = words.last!
                let login = String(credential.split(separator: "/").first!)
                let pw = credential.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
                let loginUser = String(login.split(separator: "[").first!).uppercased()
                let saveName = words.firstIndex(of: "-save").map { words[$0 + 1] }
                if passwords[loginUser] == pw && !(saveName.map { failSaving.contains($0) } ?? false) {
                    user = (login.contains("[") ? String(login.split(separator: "[")[1].dropLast()) : login).uppercased()
                    out.append("Connected.")
                    if let saveName {
                        connections.removeAll { $0.name == saveName }
                        connections.append(SavedConnection(name: saveName, user: login,
                                                           connectString: String(credential.split(separator: "@").last!)))
                    }
                } else {
                    user = ""
                    out += ["Connection failed", "  Error Message = ORA-01017: invalid credential or not authorized; logon denied"]
                }
            } else if line == "show user" {
                out.append("USER is \"\(user)\"")
            } else if line.hasPrefix("alter user ") {
                if user.isEmpty {
                    out.append("SP2-0640: Not connected")
                } else {
                    let name = words[2].uppercased()
                    let pw = line.split(separator: "\"")[1]
                    passwords[name] = String(pw)
                    out.append("User \(name) altered.")
                }
            } else if line.hasPrefix("select 1 from dual") {
                out.append(user.isEmpty ? "SP2-0640: Not connected" : "1")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

final class FakeTerminal: Terminal {
    var isInteractive = false
    var answers: [Bool] = []
    /// What standard input holds for `add`'s current-password read.
    var stdin: String?
    var stdinReads = 0
    func confirm(_ question: String) -> Bool { answers.isEmpty ? false : answers.removeFirst() }
    func readStandardInputSecret() -> String? {
        stdinReads += 1
        return stdin
    }
}

final class FakeLogin: LoginChecking {
    var status = 200
    var accept: String?
    var calls: [URL] = []
    func login(url: URL, username: String, password: String) throws -> (status: Int, body: Data) {
        calls.append(url)
        if status != 200 { return (status, Data()) }
        if password == accept { return (200, Data(#"{"access_token":"abc.def.ghi"}"#.utf8)) }
        return (401, Data())
    }
}

/// Deterministic randomness for the generator: cycles through the given values.
final class SequenceRandom: RandomSource {
    var values: [Int]
    var index = 0
    init(_ values: [Int]) { self.values = values }
    func uniform(_ upperBound: Int) -> Int {
        defer { index += 1 }
        return values[index % values.count] % upperBound
    }
}

/// A temporary directory with road-atlas fixtures, a wallet and a project, plus an App over fakes.
final class Harness {
    let root: URL
    let store = MemoryStore()
    let runner = FakeRunner()
    let terminal = FakeTerminal()
    let login = FakeLogin()
    var out: [String] = []
    var err: [String] = []
    var ignored = true
    var clipboard: String?
    /// Environment for the App; ROAD_PROJECTS points at root, where the road-kit project is.
    lazy var environment: [String: String] = [
        "ROAD_ATLAS": root.appendingPathComponent("atlas").path,
        "PATH": root.appendingPathComponent("bin").path,
        "ROAD_PROJECTS": root.path,
    ]

    static let databases = """
        # comment
        db | quoratedb | quorate_admin | active | The working database.
        db | roadkitdb | roadkit_admin | active | Demo database.
        db | olddb     | -             | deleted | Gone.
        """

    static let environments = """
        host | quoratedb  | https://example-quoratedb.adb.uk-cardiff-1.oraclecloudapps.com
        host | roadkitdb  | unknown
        env | road-blogger | prod | quoratedb | ROAD_BLOGGER_FREE_DEV | road_blogger_free_dev | roadblogdev | external_oidc | Auth0
        env | road-kit     | dev  | quoratedb | ROAD_KIT_DEV          | road_kit_dev          | hello_api   | ords_local_jwt_scaffold | ROAD_TEST_PASSWORD in config/local.env
        conn | roadkit_admin | [oracle] | ADMIN on roadkitdb
        """

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rs-test-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("atlas"), withIntermediateDirectories: true)
        try Self.databases.write(to: root.appendingPathComponent("atlas/databases.conf"), atomically: true, encoding: .utf8)
        try Self.environments.write(to: root.appendingPathComponent("atlas/environments.conf"), atomically: true, encoding: .utf8)
        for db in ["roadkitdb", "quoratedb"] {
            let wallet = root.appendingPathComponent("wallets/\(db)")
            try fm.createDirectory(at: wallet, withIntermediateDirectories: true)
            try "\(db)_medium = (description=...)\n\(db)_high = (description=...)\n"
                .write(to: wallet.appendingPathComponent("tnsnames.ora"), atomically: true, encoding: .utf8)
            try "secret".write(to: wallet.appendingPathComponent("credentials.sso"), atomically: true, encoding: .utf8)
        }
        let project = root.appendingPathComponent("road-kit")
        try fm.createDirectory(at: project.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: project.appendingPathComponent("config"), withIntermediateDirectories: true)
        let script = project.appendingPathComponent("bin/set-principal-password.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "API_BASE_PATH=hello_api\n".write(to: project.appendingPathComponent("road.config"), atomically: true, encoding: .utf8)
        // A fake sql on PATH; FakeRunner intercepts it by name.
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let sql = root.appendingPathComponent("bin/sql")
        try "#!/bin/sh\n".write(to: sql, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sql.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func wallet(_ db: String) -> String { root.appendingPathComponent("wallets/\(db)").path }
    var project: URL { root.appendingPathComponent("road-kit") }

    func app(random: RandomSource = SecureRandom()) -> App {
        App(Dependencies(
            store: store, runner: runner, terminal: terminal, login: login,
            generator: PasswordGenerator(random: random),
            environment: environment,
            home: root, currentDirectory: URL(fileURLWithPath: "/"), now: { Date(timeIntervalSince1970: 1_795_000_000) },
            out: { [unowned self] in self.out.append($0) },
            err: { [unowned self] in self.err.append($0) },
            copyToClipboard: { [unowned self] in self.clipboard = $0; return true },
            isLocalEnvIgnored: { [unowned self] _ in self.ignored }))
    }

    @discardableResult
    func run(_ args: String) -> Int32 { app().main(args.split(separator: " ").map(String.init)) }

    /// Everything printed, to check that no password leaked.
    var printed: String { (out + err).joined(separator: "\n") }
}
