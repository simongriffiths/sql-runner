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

    func adoptAdmin(_ h: Harness) throws {
        h.terminal.isInteractive = true
        h.terminal.secret = "Admin.Pass.001"
        let code = h.run("set road/roadkitdb/dev/db/ADMIN --connection roadkit_admin --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium")
        #expect(code == 0, "\(h.err)")
        h.terminal.isInteractive = false
        h.terminal.secret = nil
    }

    @Test func adoptsAdminByTypingItsPasswordThenRotates() throws {
        let h = try harness()
        try adoptAdmin(h)
        let stored = try #require(try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN"))
        #expect(stored != "Admin.Pass.001")
        #expect(h.runner.passwords["ADMIN"] == stored)
        // roadkit_admin was re-saved with the new password.
        let script = h.runner.sqlScripts.first { $0.contains("-save roadkit_admin") }
        #expect(script?.contains("-replace ADMIN/\"\(stored)\"@roadkitdb_medium") == true)
        #expect(!h.printed.contains(stored) && !h.printed.contains("Admin.Pass.001"))
        #expect(try h.store.read(service: "road-previous/roadkitdb/dev/db", account: "ADMIN") == nil)
        // Self-change used the old password with replace.
        #expect(h.runner.sqlScripts.contains { $0.contains("replace \"Admin.Pass.001\"") })

        // A second set rotates without a prompt, as a self-change.
        #expect(h.run("set road/roadkitdb/dev/db/ADMIN") == 0)
        let rotated = try #require(try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN"))
        #expect(rotated != stored && h.runner.passwords["ADMIN"] == rotated)
        #expect(h.run("check road/roadkitdb/dev/db/ADMIN") == 0)
    }

    @Test func viaAdminReSavesEveryProxyConnectionOnTheDatabase() throws {
        let h = try harness()
        try adoptAdmin(h)
        // Two connections: needs --yes when not a terminal.
        #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY --via-admin --connection livehub_a --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 2)
        #expect(h.runner.passwords["LIVEHUB_DEPLOY"] == "Old.Pass.002")
        #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY --via-admin --yes --connection livehub_a --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 0)
        let pw = try #require(try h.store.read(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY"))
        #expect(h.runner.passwords["LIVEHUB_DEPLOY"] == pw)
        // Both roadkitdb connections re-saved with their proxy schemas; quoratedb's untouched.
        let all = h.runner.sqlScripts.joined(separator: "\n")
        #expect(all.contains("-save livehub_a -savepwd -replace livehub_deploy[a_hub]/\"\(pw)\"@roadkitdb_medium"))
        #expect(all.contains("-save livehub_b -savepwd -replace livehub_deploy[b_hub]/\"\(pw)\"@roadkitdb_high"))
        #expect(!all.contains("-save livehub_q"))
        #expect(h.out.contains { $0.contains("Re-saved 2 connection(s)") })
        let meta = Meta.decode(DbMeta.self, try h.store.attributes(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY")?.generic)
        #expect(meta?.sqlcl_connections == ["livehub_a", "livehub_b"])
        #expect(!h.printed.contains(pw))
        #expect(h.run("check road/livehub/dev/db/LIVEHUB_DEPLOY") == 0)
    }

    @Test func failedChangeRestoresTheEntry() throws {
        let h = try harness()
        try adoptAdmin(h)
        let adminPw = try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN")
        h.runner.passwords["ADMIN"] = "Changed.Elsewhere.003"   // the stored ADMIN password is now wrong
        #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY --via-admin --yes --connection livehub_a --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 5)
        #expect(try h.store.read(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY") == nil)
        #expect(try h.store.read(service: "road-previous/livehub/dev/db", account: "LIVEHUB_DEPLOY") == nil)
        #expect(try h.store.read(service: "road/roadkitdb/dev/db", account: "ADMIN") == adminPw)
        #expect(h.runner.passwords["LIVEHUB_DEPLOY"] == "Old.Pass.002")
        #expect(!h.printed.contains(adminPw!))
        #expect(h.printed.contains("ORA-01017"))
    }

    @Test func failedReSaveKeepsTheNewPasswordAndAsksForSync() throws {
        let h = try harness()
        try adoptAdmin(h)
        h.runner.failSaving = ["livehub_b"]
        #expect(h.run("set road/livehub/dev/db/LIVEHUB_DEPLOY --via-admin --yes --connection livehub_a --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 5)
        let pw = try #require(try h.store.read(service: "road/livehub/dev/db", account: "LIVEHUB_DEPLOY"))
        #expect(h.runner.passwords["LIVEHUB_DEPLOY"] == pw)
        #expect(h.err.contains { $0.contains("livehub_b") && $0.contains("road-secrets sync") })
        h.runner.failSaving = []
        h.out = []
        #expect(h.run("sync road/livehub/dev/db/LIVEHUB_DEPLOY") == 0)
        #expect(h.out.contains { $0.contains("2 connection(s)") })
    }

    @Test func notATerminalCannotAdopt() throws {
        let h = try harness()
        #expect(h.run("set road/roadkitdb/dev/db/ADMIN --connection roadkit_admin --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 2)
        #expect(h.store.items.isEmpty)
    }

    @Test func productionAndNamingRefusals() throws {
        let h = try harness()
        h.terminal.isInteractive = true
        h.terminal.secret = "Admin.Pass.001"
        // quoratedb serves production, so its ADMIN is refused with 6.
        #expect(h.run("set road/quoratedb/dev/db/ADMIN --connection quorate_admin --wallet \(h.wallet("quoratedb")) --tns quoratedb_high") == 6)
        // The schema of a prod env line is refused.
        h.runner.passwords["ROAD_BLOGGER_FREE_DEV"] = "x"
        #expect(h.run("set road/road-blogger/dev/db/ROAD_BLOGGER_FREE_DEV --connection road_blogger_free_dev --wallet \(h.wallet("quoratedb")) --tns quoratedb_high") == 6)
        // An ADMIN key must be named after its database.
        #expect(h.run("set road/road-kit/dev/db/ADMIN --connection roadkit_admin --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 2)
        // The connection must log in as NAME.
        #expect(h.run("set road/x/dev/db/LIVEHUB_DEPLOY --connection roadkit_admin --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 2)
        // Missing options are named.
        #expect(h.run("set road/x/dev/db/LIVEHUB_DEPLOY") == 2)
        #expect(h.err.last?.contains("--connection, --wallet, --tns") == true)
        // A TNS name the wallet does not define.
        #expect(h.run("set road/x/dev/db/LIVEHUB_DEPLOY --connection livehub_a --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_low") == 2)
        // --via-admin with no ADMIN entry.
        #expect(h.run("set road/x/dev/db/LIVEHUB_DEPLOY --via-admin --yes --connection livehub_a --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 2)
        #expect(h.store.items.isEmpty)
        #expect(h.runner.passwords["ADMIN"] == "Admin.Pass.001")
    }

    @Test func unreadableAtlasRefuses() throws {
        let h = try harness()
        try FileManager.default.removeItem(at: h.root.appendingPathComponent("atlas/environments.conf"))
        #expect(h.run("set road/roadkitdb/dev/db/ADMIN --connection roadkit_admin --wallet \(h.wallet("roadkitdb")) --tns roadkitdb_medium") == 6)
    }
}

@Suite struct PrincipalCommandTests {
    @Test func setWritesTwiceOnStdinThenUpdatesLocalEnv() throws {
        let h = try Harness()
        let env = h.project.appendingPathComponent("config/local.env")
        try "export ROAD_ORDS_HOST=https://h\nexport ROAD_TEST_PASSWORD='old'\n".write(to: env, atomically: true, encoding: .utf8)
        #expect(h.run("set road/road-kit/dev/principal/ADMIN") == 0, "\(h.err)")
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

        // local.env drifts: check fails, sync repairs it.
        try "export ROAD_TEST_PASSWORD='drift'\n".write(to: env, atomically: true, encoding: .utf8)
        #expect(h.run("check road/road-kit/dev/principal/ADMIN") == 5)
        #expect(h.run("sync road/road-kit/dev/principal/ADMIN") == 0)
        #expect(h.run("check road/road-kit/dev/principal/ADMIN") == 0)

        h.login.status = 404
        #expect(h.run("check road/road-kit/dev/principal/ADMIN") == 5)
    }

    @Test func scriptFailureRestores() throws {
        let h = try Harness()
        h.runner.principalScriptStatus = 1
        #expect(h.run("set road/road-kit/dev/principal/ADMIN") == 5)
        #expect(h.store.items.isEmpty)
    }

    @Test func refusesTheWrongProjectAndUnignoredLocalEnv() throws {
        let h = try Harness()
        #expect(h.run("set road/road-cal/dev/principal/ADMIN") == 2)
        try "x=1\n".write(to: h.project.appendingPathComponent("config/local.env"), atomically: true, encoding: .utf8)
        h.ignored = false
        #expect(h.run("set road/road-kit/dev/principal/ADMIN") == 5)
        // The principal already has the new password, so the entry is kept.
        #expect(try h.store.read(service: "road/road-kit/dev/principal", account: "ADMIN") != nil)
    }

    @Test func missingLocalEnvIsNotAFailure() throws {
        let h = try Harness()
        #expect(h.run("set road/road-kit/dev/principal/ALICE") == 0)
        #expect(h.out.last?.contains("No config/local.env") == true)
        #expect(h.run("check road/road-kit/dev/principal/ALICE") == 5)   // FakeLogin accepts nothing
    }
}
