import Foundation
import Testing
@testable import RoadSecretsCore

@Suite struct StoreCommandTests {
    @Test func initWritesReadsAndDeletes() throws {
        let h = try Harness()
        #expect(h.run("init") == 0)
        #expect(h.out == ["road-secrets: login keychain OK"])
        #expect(h.store.items.isEmpty)
    }

    @Test func listGetCopyDelete() throws {
        let h = try Harness()
        let key = try Key.parse("road/demo/dev/db/THROWAWAY")
        try h.store.write(service: key.service, account: key.account, password: "Brave.Otter.042",
                          label: key.label, comment: "set 2026-11-24", generic: nil)
        try h.store.write(service: key.previousService, account: key.account, password: "Quiet.Lake.001",
                          label: key.label, comment: "set 2026-11-20", generic: nil)
        try h.store.write(service: "road-secrets/init-check", account: "road", password: "x", label: "", comment: "", generic: nil)

        #expect(h.run("list") == 0)
        #expect(h.out == ["road/demo/dev/db/THROWAWAY\t2026-11-24\tdemo dev db THROWAWAY"])
        h.out = []
        #expect(h.run("list road/demo --all") == 0)
        #expect(h.out.count == 2 && h.out[1].hasSuffix("\t(previous)"))
        h.out = []
        #expect(h.run("list road/other") == 0)
        #expect(h.out.isEmpty)

        #expect(h.run("get road/demo/dev/db/THROWAWAY") == 0)
        #expect(h.out == ["Brave.Otter.042"])
        #expect(h.run("copy road/demo/dev/db/THROWAWAY") == 0)
        #expect(h.clipboard == "Brave.Otter.042")
        #expect(h.run("get road/demo/dev/db/MISSING") == 3)

        // Not a terminal and no --yes: refused, nothing deleted.
        #expect(h.run("delete road/demo/dev/db/THROWAWAY") == 2)
        #expect(try h.store.read(service: key.service, account: key.account) != nil)
        #expect(h.run("delete road/demo/dev/db/THROWAWAY --yes") == 0)
        #expect(try h.store.read(service: key.service, account: key.account) == nil)
        #expect(try h.store.read(service: key.previousService, account: key.account) == nil)
        #expect(h.run("delete road/demo/dev/db/THROWAWAY --yes") == 3)
    }

    @Test func usageErrors() throws {
        let h = try Harness()
        #expect(h.run("frobnicate") == 2)
        #expect(h.run("get") == 2)
        #expect(h.run("get road/demo/dev/db/lower") == 2)
        #expect(h.run("set road/demo/dev/db/X --bogus") == 2)
        #expect(h.run("get road/demo/prod/db/X") == 6)
    }
}

@Suite struct DbCommandTests {
    /// roadkitdb with LIVEHUB_DEPLOY behind two proxy connections, and an ADMIN connection.
    func harness() throws -> Harness {
        let h = try Harness()
        h.runner.connections = [
            SavedConnection(name: "roadkit_admin", user: "ADMIN", connectString: "roadkitdb_medium"),
            SavedConnection(name: "livehub_a", user: "livehub_deploy[a_hub]", connectString: "roadkitdb_medium"),
            SavedConnection(name: "livehub_b", user: "livehub_deploy[b_hub]", connectString: "roadkitdb_high"),
            SavedConnection(name: "livehub_q", user: "livehub_deploy[q_hub]", connectString: "quoratedb_medium"),
            SavedConnection(name: "road_blogger_free_dev", user: "ROAD_BLOGGER_FREE_DEV", connectString: "quoratedb_high"),
            SavedConnection(name: "quorate_admin", user: "ADMIN", connectString: "quoratedb_high"),
        ]
        h.runner.passwords = ["ADMIN": "Admin.Pass.001", "LIVEHUB_DEPLOY": "Old.Pass.002"]
        return h
    }

    func details(_ h: Harness, _ connection: String, db: String = "roadkitdb", tns: String = "roadkitdb_medium") -> String {
        "--connection \(connection) --wallet \(h.wallet(db)) --tns \(tns)"
    }

    func addAdmin(_ h: Harness) throws {
        h.terminal.stdin = "Admin.Pass.001"
        h.out = []
        let code = h.run("add --app roadkitdb --env dev --kind db --name ADMIN \(details(h, "roadkit_admin"))")
        #expect(code == 0, "\(h.err)")
        #expect(h.out == ["road/roadkitdb/dev/db/ADMIN"])
        h.terminal.stdin = nil
    }

    @Test func addAdoptsAdminFromStandardInputThenSetRotates() throws {
        let h = try harness()
        try addAdmin(h)
        #expect(h.terminal.stdinReads == 1)
        let stored = try #require(try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN"))
        #expect(stored != "Admin.Pass.001")
        #expect(h.runner.passwords["ADMIN"] == stored)
        let script = h.runner.sqlScripts.first { $0.contains("-save roadkit_admin") }
        #expect(script?.contains("-replace ADMIN/\"\(stored)\"@roadkitdb_medium") == true)
        #expect(!h.printed.contains(stored) && !h.printed.contains("Admin.Pass.001"))
        #expect(h.runner.sqlScripts.contains { $0.contains("replace \"Admin.Pass.001\"") })

        // set takes only the key, from any folder, and reads nothing from standard input.
        #expect(h.run("set road/roadkitdb/dev/db/ADMIN") == 0, "\(h.err)")
        #expect(h.terminal.stdinReads == 1)
        let rotated = try #require(try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN"))
        #expect(rotated != stored && h.runner.passwords["ADMIN"] == rotated)
        #expect(h.run("check road/roadkitdb/dev/db/ADMIN") == 0)
        #expect(h.run("sync road/roadkitdb/dev/db/ADMIN") == 0)
    }

    @Test func addViaAdminReSavesEveryProxyConnectionOnTheDatabase() throws {
        let h = try harness()
        try addAdmin(h)
        // Two connections: add never asks, so --yes is required.
        #expect(h.run("add --app livehub --env dev --kind db --name LIVEHUB_DEPLOY --via-admin \(details(h, "livehub_a"))") == 2)
        #expect(h.runner.passwords["LIVEHUB_DEPLOY"] == "Old.Pass.002")
        #expect(try h.store.read(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY") == nil)
        #expect(h.run("add --app livehub --env dev --kind db --name LIVEHUB_DEPLOY --via-admin --yes \(details(h, "livehub_a"))") == 0)
        #expect(h.terminal.stdinReads == 1)  // --via-admin reads nothing
        let pw = try #require(try h.store.read(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY"))
        #expect(h.runner.passwords["LIVEHUB_DEPLOY"] == pw)
        let all = h.runner.sqlScripts.joined(separator: "\n")
        #expect(all.contains("-save livehub_a -savepwd -replace livehub_deploy[a_hub]/\"\(pw)\"@roadkitdb_medium"))
        #expect(all.contains("-save livehub_b -savepwd -replace livehub_deploy[b_hub]/\"\(pw)\"@roadkitdb_high"))
        #expect(!all.contains("-save livehub_q"))
        #expect(h.err.contains { $0.contains("Re-saved 2 connection(s)") })
        let meta = Meta.decode(DbMeta.self, try h.store.attributes(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY")?.generic)
        #expect(meta?.sqlcl_connections == ["livehub_a", "livehub_b"])
        #expect(meta?.connection == "livehub_a")
        #expect(!h.printed.contains(pw))
        #expect(h.run("check road/livehub/dev/db/LIVEHUB_DEPLOY") == 0)
        // set on several connections still needs --yes when not at a terminal.
        #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY") == 2)
        #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY --yes") == 0)
        #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY --yes --via-admin") == 0)
    }

    @Test func failedChangeRestoresTheEntry() throws {
        let h = try harness()
        try addAdmin(h)
        let adminPw = try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN")
        h.runner.passwords["ADMIN"] = "Changed.Elsewhere.003"
        #expect(h.run("add --app livehub --env dev --kind db --name LIVEHUB_DEPLOY --via-admin --yes \(details(h, "livehub_a"))") == 5)
        #expect(try h.store.read(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY") == nil)
        #expect(try h.store.read(service: "road-previous/livehub/dev/db", account: "LIVEHUB_DEPLOY") == nil)
        #expect(try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN") == adminPw)
        #expect(h.runner.passwords["LIVEHUB_DEPLOY"] == "Old.Pass.002")
        #expect(!h.printed.contains(adminPw!))
        #expect(h.printed.contains("ORA-01017"))

        // A failed set keeps the old entry.
        h.runner.passwords["ADMIN"] = "Changed.Elsewhere.004"
        #expect(h.run("set road/roadkitdb/dev/db/ADMIN") == 5)
        #expect(try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN") == adminPw)
        #expect(try h.store.read(service: "road-previous/roadkitdb/dev/db", account: "ADMIN") == nil)
    }

    @Test func failedReSaveKeepsTheNewPasswordAndAsksForSync() throws {
        let h = try harness()
        try addAdmin(h)
        h.runner.failSaving = ["livehub_b"]
        #expect(h.run("add --app livehub --env dev --kind db --name LIVEHUB_DEPLOY --via-admin --yes \(details(h, "livehub_a"))") == 5)
        let pw = try #require(try h.store.read(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY"))
        #expect(h.runner.passwords["LIVEHUB_DEPLOY"] == pw)
        #expect(h.err.contains { $0.contains("livehub_b") && $0.contains("road-secrets sync") })
        h.runner.failSaving = []
        h.out = []
        #expect(h.run("sync road/livehub/dev/db/LIVEHUB_DEPLOY") == 0)
        #expect(h.out.contains { $0.contains("2 connection(s)") })
    }

    @Test func addWithEmptyStandardInputSuggestsViaAdmin() throws {
        let h = try harness()
        #expect(h.run("add --app roadkitdb --env dev --kind db --name ADMIN \(details(h, "roadkit_admin"))") == 2)
        #expect(h.err.last?.contains("--via-admin") == true)
        #expect(h.store.items.isEmpty)
    }

    @Test func productionAndNamingRefusals() throws {
        let h = try harness()
        h.terminal.stdin = "Admin.Pass.001"
        #expect(h.run("add --app quoratedb --env dev --kind db --name ADMIN \(details(h, "quorate_admin", db: "quoratedb", tns: "quoratedb_high"))") == 6)
        h.runner.passwords["ROAD_BLOGGER_FREE_DEV"] = "x"
        #expect(h.run("add --app road-blogger --env dev --kind db --name ROAD_BLOGGER_FREE_DEV \(details(h, "road_blogger_free_dev", db: "quoratedb", tns: "quoratedb_high"))") == 6)
        #expect(h.run("add --app road-kit --env dev --kind db --name ADMIN \(details(h, "roadkit_admin"))") == 2)
        #expect(h.err.last?.contains("--app roadkitdb") == true)
        #expect(h.run("add --app x --env dev --kind db --name LIVEHUB_DEPLOY \(details(h, "roadkit_admin"))") == 2)
        #expect(h.run("add --app x --env dev --kind db --name LIVEHUB_DEPLOY") == 2)
        #expect(h.err.last?.contains("--connection, --wallet, --tns") == true)
        #expect(h.run("add --app x --env dev --kind db --name LIVEHUB_DEPLOY \(details(h, "livehub_a", tns: "roadkitdb_low"))") == 2)
        #expect(h.run("add --app x --env dev --kind db --name LIVEHUB_DEPLOY --via-admin --yes \(details(h, "livehub_a"))") == 2)
        #expect(h.store.items.isEmpty)
        #expect(h.runner.passwords["ADMIN"] == "Admin.Pass.001")
    }

    @Test func refusalsComeBeforeReadingStandardInput() throws {
        let h = try harness()
        #expect(h.run("add --app quoratedb --env dev --kind db --name ADMIN \(details(h, "quorate_admin", db: "quoratedb", tns: "quoratedb_high"))") == 6)
        #expect(h.run("add --app road-kit --env dev --kind db --name ADMIN \(details(h, "roadkit_admin"))") == 2)
        #expect(h.terminal.stdinReads == 0)
    }

    @Test func unreadableAtlasRefuses() throws {
        let h = try harness()
        h.terminal.stdin = "Admin.Pass.001"
        try FileManager.default.removeItem(at: h.root.appendingPathComponent("atlas/environments.conf"))
        #expect(h.run("add --app roadkitdb --env dev --kind db --name ADMIN \(details(h, "roadkit_admin"))") == 6)
    }
}

@Suite struct AddCommandTests {
    @Test(arguments: [
        ("add", 2),                                                       // nothing given
        ("add --app road-kit --env dev --name ADMIN", 2),                 // --kind is required
        ("add --app road-kit --env dev --kind table --name ADMIN", 2),    // unknown kind
        ("add --app road-kit --env dev --kind principal --name admin", 2),// lowercase name
        ("add --app Road-Kit --env dev --kind principal --name ADMIN", 2),// bad app
        ("add --app road-kit --env prod --kind principal --name ADMIN", 6),
        ("add road/road-kit/dev/principal/ADMIN", 2),                     // add takes no key
        ("add --app road-kit --env dev --kind principal --name ADMIN --tns x_high", 2),
        ("add --app road-kit --env dev --kind db --name X --project /tmp", 2),
        ("add --app road-kit --env dev --kind principal --name ADMIN --bogus", 2),
    ])
    func validation(_ command: String, _ expected: Int32) throws {
        let h = try Harness()
        #expect(h.run(command) == expected, "\(h.err)")
        #expect(h.store.items.isEmpty)
        #expect(h.runner.calls.isEmpty)
    }

    @Test func refusesAnExistingKey() throws {
        let h = try Harness()
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN") == 0, "\(h.err)")
        let first = try h.store.read(service: "road/road-kit/dev/principal", account: "ADMIN")
        let calls = h.runner.calls.count
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN") == 2)
        #expect(h.err.last?.contains("road-secrets set road/road-kit/dev/principal/ADMIN") == true)
        #expect(try h.store.read(service: "road/road-kit/dev/principal", account: "ADMIN") == first)
        #expect(h.runner.calls.count == calls)
    }

    @Test(arguments: ["set", "sync", "check"])
    func missingKeysPointToAdd(_ command: String) throws {
        let h = try Harness()
        #expect(h.run("\(command) road/road-kit/dev/principal/ADMIN") == 3)
        #expect(h.err.last?.contains("road-secrets add --app road-kit --env dev --kind principal --name ADMIN") == true)
        #expect(h.run("\(command) road/livehub/dev/db/LIVEHUB_DEPLOY") == 3)
        #expect(h.err.last?.contains("--kind db") == true)
    }

    @Test func setTakesNoFirstTimeOptions() throws {
        let h = try Harness()
        for option in ["--connection x", "--wallet /x", "--tns x_high", "--ords-url https://x"] {
            #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY \(option)") == 2)
        }
        #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY --project /x") == 2)
        #expect(h.run("set road/road-kit/dev/principal/ADMIN --via-admin") == 2)
        #expect(h.run("get road/road-kit/dev/principal/ADMIN extra") == 2)
    }
}

@Suite struct ProjectFolderTests {
    func setUpProject(at folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("bin/set-principal-password.sh")
        try "#!/bin/sh\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    func scriptDirectory(_ h: Harness) -> String? {
        h.runner.calls.last { $0.executable.hasSuffix("set-principal-password.sh") }?.executable
    }

    @Test func defaultsToRoadProjects() throws {
        let h = try Harness()
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN") == 0)
        #expect(scriptDirectory(h) == h.project.appendingPathComponent("bin/set-principal-password.sh").path)
    }

    @Test func defaultsToHomeProjectsWithoutRoadProjects() throws {
        let h = try Harness()
        h.environment["ROAD_PROJECTS"] = nil
        let folder = h.root.appendingPathComponent("Projects/road-kit")
        try setUpProject(at: folder)
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN") == 0, "\(h.err)")
        #expect(scriptDirectory(h) == folder.appendingPathComponent("bin/set-principal-password.sh").path)
        let meta = Meta.decode(PrincipalMeta.self, try h.store.attributes(service: "road/road-kit/dev/principal", account: "ADMIN")?.generic)
        #expect(meta?.project == folder.path)
    }

    @Test func storedProjectWinsOverTheDefaultAndOverrideWinsOverBoth() throws {
        let h = try Harness()
        let elsewhere = h.root.appendingPathComponent("elsewhere/road-kit")
        try setUpProject(at: elsewhere)
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN --project \(elsewhere.path)") == 0)
        #expect(h.run("set road/road-kit/dev/principal/ADMIN") == 0)
        #expect(scriptDirectory(h) == elsewhere.appendingPathComponent("bin/set-principal-password.sh").path)
        #expect(h.run("set road/road-kit/dev/principal/ADMIN --project \(h.project.path)") == 0)
        #expect(scriptDirectory(h) == h.project.appendingPathComponent("bin/set-principal-password.sh").path)
        // The override is stored for next time.
        let meta = Meta.decode(PrincipalMeta.self, try h.store.attributes(service: "road/road-kit/dev/principal", account: "ADMIN")?.generic)
        #expect(meta?.project == h.project.path)
    }

    @Test func aMissingProjectNamesTheFolderAndSuggestsProject() throws {
        let h = try Harness()
        h.environment["ROAD_PROJECTS"] = "/nonexistent"
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN") == 2)
        #expect(h.err.last?.contains("/nonexistent/road-kit") == true && h.err.last?.contains("--project") == true)
        #expect(h.store.items.isEmpty)
    }
}

@Suite struct PrincipalCommandTests {
    @Test func addWritesTwiceOnStdinThenUpdatesLocalEnv() throws {
        let h = try Harness()
        let env = h.project.appendingPathComponent("config/local.env")
        try "export ROAD_ORDS_HOST=https://h\nexport ROAD_TEST_PASSWORD='old'\n".write(to: env, atomically: true, encoding: .utf8)
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN") == 0, "\(h.err)")
        #expect(h.out == ["road/road-kit/dev/principal/ADMIN"])
        let pw = try #require(try h.store.read(service: "road/road-kit/dev/principal", account: "ADMIN"))
        let call = try #require(h.runner.calls.first { $0.executable.hasSuffix("set-principal-password.sh") })
        #expect(call.arguments == ["--env", "dev", "--subject", "ADMIN"])
        #expect(call.stdin == "\(pw)\n\(pw)\n")
        #expect(try String(contentsOf: env, encoding: .utf8).contains("export ROAD_TEST_PASSWORD='\(pw)'"))
        #expect(h.err.contains { $0.contains("every live session") })
        let meta = Meta.decode(PrincipalMeta.self, try h.store.attributes(service: "road/road-kit/dev/principal", account: "ADMIN")?.generic)
        #expect(meta?.ords_url == "https://example-quoratedb.adb.uk-cardiff-1.oraclecloudapps.com/ords")
        #expect(!h.printed.contains(pw))

        h.login.accept = pw
        h.out = []
        #expect(h.run("check road/road-kit/dev/principal/ADMIN") == 0)
        #expect(h.login.calls.last?.absoluteString == "https://example-quoratedb.adb.uk-cardiff-1.oraclecloudapps.com/ords/hello_api/jwt-auth/login")
        #expect(h.out.contains("ok: config/local.env matches the Keychain"))

        try "export ROAD_TEST_PASSWORD='drift'\n".write(to: env, atomically: true, encoding: .utf8)
        #expect(h.run("check road/road-kit/dev/principal/ADMIN") == 5)
        #expect(h.run("sync road/road-kit/dev/principal/ADMIN") == 0)
        #expect(h.run("check road/road-kit/dev/principal/ADMIN") == 0)

        // set rotates with only the key.
        #expect(h.run("set road/road-kit/dev/principal/ADMIN") == 0)
        let rotated = try #require(try h.store.read(service: "road/road-kit/dev/principal", account: "ADMIN"))
        #expect(rotated != pw)
        #expect(try String(contentsOf: env, encoding: .utf8).contains("'\(rotated)'"))

        h.login.status = 404
        #expect(h.run("check road/road-kit/dev/principal/ADMIN") == 5)
    }

    @Test func ordsUrlCanBeGivenToAdd() throws {
        let h = try Harness()
        #expect(h.run("add --app road-kit --env dev --kind principal --name ALICE --ords-url https://given/ords") == 0)
        let meta = Meta.decode(PrincipalMeta.self, try h.store.attributes(service: "road/road-kit/dev/principal", account: "ALICE")?.generic)
        #expect(meta?.ords_url == "https://given/ords")
    }

    @Test func scriptFailureRestores() throws {
        let h = try Harness()
        h.runner.principalScriptStatus = 1
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN") == 5)
        #expect(h.store.items.isEmpty)
    }

    @Test func refusesTheWrongProjectAndUnignoredLocalEnv() throws {
        let h = try Harness()
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN --project \(h.root.path)") == 2)
        try "x=1\n".write(to: h.project.appendingPathComponent("config/local.env"), atomically: true, encoding: .utf8)
        h.ignored = false
        #expect(h.run("add --app road-kit --env dev --kind principal --name ADMIN") == 5)
        #expect(try h.store.read(service: "road/road-kit/dev/principal", account: "ADMIN") != nil)
    }

    @Test func missingLocalEnvIsNotAFailure() throws {
        let h = try Harness()
        #expect(h.run("add --app road-kit --env dev --kind principal --name ALICE") == 0)
        #expect(h.err.last?.contains("No config/local.env") == true)
        #expect(h.run("check road/road-kit/dev/principal/ALICE") == 5)
    }
}
