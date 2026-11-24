import Foundation
import Testing
@testable import RoadSecretsCore

@Suite struct KeyTests {
    @Test func parsesAValidKey() throws {
        let key = try Key.parse("road/road-cal/dev/principal/ALICE")
        #expect(key == Key(app: "road-cal", env: "dev", kind: .principal, name: "ALICE"))
        #expect(key.service == "road/road-cal/dev/principal")
        #expect(key.previousService == "road-previous/road-cal/dev/principal")
        #expect(key.account == "ALICE")
        #expect(key.label == "road-cal dev principal ALICE")
        #expect(key.description == "road/road-cal/dev/principal/ALICE")
    }

    @Test(arguments: [
        "road/road-cal/dev/db/alice",          // lowercase NAME is rejected, not converted
        "road/Road-Cal/dev/db/ALICE",
        "road/road_cal/dev/db/ALICE",
        "road/road-cal/dev/table/ALICE",
        "road/road-cal/dev/db",
        "road/road-cal/dev/db/ALICE/extra",
        "roads/road-cal/dev/db/ALICE",
        "road//dev/db/ALICE",
        "road/road-cal/dev/db/AL ICE",
    ])
    func rejectsInvalidKeys(_ text: String) {
        #expect(throws: RoadError.self) { try Key.parse(text) }
        #expect((try? Key.parse(text)) == nil)
        do { _ = try Key.parse(text) } catch let e as RoadError { #expect(e.code == .usage) } catch {}
    }

    @Test func acceptsNameSymbols() throws {
        _ = try Key.parse("road/x/dev/db/A_B.C@D$E#F-1")
    }

    @Test func prodIsRefusedWithExit6() {
        do {
            _ = try Key.parse("road/road-cal/prod/db/ALICE")
            Issue.record("expected a refusal")
        } catch let e as RoadError {
            #expect(e.code == .refused)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func rebuildsFromKeychainAttributes() {
        let current = Key.from(service: "road/road-cal/dev/db", account: "ROAD_CAL_SCHEMA")
        #expect(current?.key.description == "road/road-cal/dev/db/ROAD_CAL_SCHEMA")
        #expect(current?.previous == false)
        let previous = Key.from(service: "road-previous/road-cal/dev/db", account: "ROAD_CAL_SCHEMA")
        #expect(previous?.previous == true)
        #expect(Key.from(service: "road-secrets/init-check", account: "road") == nil)
        #expect(Key.from(service: "something-else", account: "X") == nil)
    }

    @Test func adminIsOnlyADbKey() throws {
        #expect(try Key.parse("road/roadkitdb/dev/db/ADMIN").isAdmin)
        #expect(!(try Key.parse("road/road-kit/dev/principal/ADMIN").isAdmin))
    }
}

@Suite struct PasswordTests {
    @Test func tenThousandPasswordsHaveTheRightShape() {
        let generator = PasswordGenerator()
        for _ in 0..<10_000 {
            let p = generator.generate(avoiding: ["ADMIN"])
            let parts = p.split(separator: ".", omittingEmptySubsequences: false)
            #expect(parts.count == 3)
            #expect((13...21).contains(p.count))
            #expect(p.contains { $0.isUppercase } && p.contains { $0.isLowercase } && p.contains { $0.isNumber })
            #expect(parts[2].count == 3 && parts[2].allSatisfy(\.isNumber))
            for word in parts.prefix(2) {
                #expect(word.first!.isUppercase && word.dropFirst().allSatisfy(\.isLowercase))
            }
            #expect(!p.lowercased().contains("admin"))
            #expect(!p.contains("'") && !p.contains("\""))
        }
    }

    @Test func numberIsZeroPadded() {
        let g = PasswordGenerator(adjectives: ["brave"], nouns: ["otter"], random: SequenceRandom([0, 0, 42]))
        #expect(g.generate() == "Brave.Otter.042")
    }

    @Test func regeneratesWhenTheNameAppears() {
        // First draw contains OTTER, second does not.
        let g = PasswordGenerator(adjectives: ["brave", "quiet"], nouns: ["otter", "meadow"],
                                  random: SequenceRandom([0, 0, 7, 1, 1, 8]))
        #expect(g.generate(avoiding: ["OTTER"]) == "Quiet.Meadow.008")
    }

    @Test func secureRandomStaysInRange() {
        let r = SecureRandom()
        var seen = Set<Int>()
        for _ in 0..<2_000 {
            let v = r.uniform(7)
            #expect((0..<7).contains(v))
            seen.insert(v)
        }
        #expect(seen.count == 7)
    }
}

@Suite struct WordListTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func read(_ name: String) throws -> [String] {
        try String(contentsOf: root.appendingPathComponent("Resources/\(name)"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    @Test(arguments: ["adjectives.txt", "nouns.txt"])
    func wordsAreValidAndUnique(_ file: String) throws {
        let words = try Self.read(file)
        #expect(words.count >= 1_000)
        #expect(Set(words).count == words.count, "duplicates in \(file)")
        for word in words { #expect(PasswordGenerator.isValidWord(word), "invalid word \(word) in \(file)") }
    }

    @Test func compiledListsMatchTheTextFiles() throws {
        #expect(WordLists.adjectives == (try Self.read("adjectives.txt")),
                "run scripts/gen-wordlists.sh")
        #expect(WordLists.nouns == (try Self.read("nouns.txt")), "run scripts/gen-wordlists.sh")
    }
}

@Suite struct AtlasTests {
    let atlas = Atlas.parse(databases: Harness.databases, environments: Harness.environments)

    @Test func readsDatabasesEnvsAndHosts() {
        #expect(atlas.isActiveDatabase("quoratedb"))
        #expect(atlas.isActiveDatabase("roadkitdb"))
        #expect(!atlas.isActiveDatabase("olddb"))
        #expect(!atlas.isActiveDatabase("nodb"))
        #expect(atlas.envs.count == 2)
        #expect(atlas.ordsBase(app: "road-kit", env: "dev") == "https://example-quoratedb.adb.uk-cardiff-1.oraclecloudapps.com/ords")
        #expect(atlas.hosts["roadkitdb"] == nil)
    }

    @Test(arguments: [
        ("quoratedb_high", "quoratedb"), ("roadkitdb_medium", "roadkitdb"), ("ROADKITDB_LOW", "roadkitdb"),
        ("mydb_tp", "mydb"), ("mydb_tpurgent", "mydb"),
        ("(description=(address=(protocol=tcps)(port=1522)(host=adb.uk-cardiff-1.oraclecloud.com))(connect_data=(service_name=geb0d0f36a9a4b0_roadkitdb_medium.adb.oraclecloud.com)))", "roadkitdb"),
    ])
    func derivesDatabaseNames(_ connect: String, _ expected: String) {
        #expect(databaseName(fromConnectString: connect) == expected)
    }

    @Test(arguments: ["quoratedb", "host:1522/service", ""])
    func rejectsUnknownSuffixes(_ connect: String) {
        #expect(databaseName(fromConnectString: connect) == nil)
    }

    func refused(_ key: String, db: String?, connections: [String] = []) -> Bool {
        do {
            try ProdGuard.check(key: try Key.parse(key), db: db, connections: connections, atlas: atlas)
            return false
        } catch let e as RoadError {
            return e.code == .refused
        } catch {
            return false
        }
    }

    @Test func guardRefusesProductionTargets() {
        #expect(refused("road/quoratedb/dev/db/ADMIN", db: "quoratedb"))
        #expect(!refused("road/roadkitdb/dev/db/ADMIN", db: "roadkitdb"))
        #expect(refused("road/road-blogger/dev/db/ROAD_BLOGGER_FREE_DEV", db: "quoratedb"))
        #expect(refused("road/x/dev/db/SOMEONE", db: "quoratedb", connections: ["ROAD_BLOGGER_FREE_DEV"]))
        #expect(!refused("road/road-kit/dev/db/ROAD_KIT_DEV", db: "quoratedb", connections: ["road_kit_dev"]))
        // Principals are checked only by environment.
        #expect(!refused("road/road-blogger/dev/principal/ROAD_BLOGGER_FREE_DEV", db: nil))
    }

    @Test func missingAtlasFailsClosed() {
        do {
            _ = try Atlas.load(root: URL(fileURLWithPath: "/nonexistent/road-atlas"))
            Issue.record("expected a refusal")
        } catch let e as RoadError {
            #expect(e.code == .refused)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func locatesAtlas() {
        let home = URL(fileURLWithPath: "/Users/x")
        #expect(Atlas.locate(environment: [:], home: home).path == "/Users/x/Projects/road-atlas")
        #expect(Atlas.locate(environment: ["ROAD_ATLAS": "/tmp/a"], home: home).path == "/tmp/a")
    }
}

@Suite struct ConnmgrTests {
    @Test func parsesLoginUsersAndProxySchemas() {
        let proxy = SavedConnection(name: "livehub_av_acc", user: "livehub_deploy[av_acc]", connectString: "quoratedb_medium")
        #expect(proxy.loginUser == "livehub_deploy")
        #expect(proxy.proxySchema == "av_acc")
        #expect(proxy.sessionUser == "AV_ACC")
        #expect(proxy.logsIn(as: "LIVEHUB_DEPLOY"))
        #expect(proxy.databaseName == "quoratedb")
        let direct = SavedConnection(name: "road_kit_dev", user: "ROAD_KIT_DEV", connectString: "quoratedb_high")
        #expect(direct.proxySchema == nil)
        #expect(direct.sessionUser == "ROAD_KIT_DEV")
    }

    @Test func parsesListAndShow() {
        #expect(Connmgr.parseListFlat("/a\n/b_c\n\nnot a name\n") == ["a", "b_c"])
        let show = """
            Name: one
            Connect String: roadkitdb_medium
            User: ADMIN
            Password: ******
            oracle.net.wallet_location: (SOURCE=(METHOD=FILE))
            Name: two
            Connect String: quoratedb_high
            User: livehub_deploy[av_hub]
            """
        let parsed = Connmgr.parseShow(show)
        #expect(parsed == [
            SavedConnection(name: "one", user: "ADMIN", connectString: "roadkitdb_medium"),
            SavedConnection(name: "two", user: "livehub_deploy[av_hub]", connectString: "quoratedb_high"),
        ])
    }

    @Test func matchesByUserAndDatabaseIgnoringCase() {
        let all = [
            SavedConnection(name: "b", user: "livehub_deploy[x]", connectString: "roadkitdb_medium"),
            SavedConnection(name: "a", user: "LIVEHUB_DEPLOY", connectString: "roadkitdb_high"),
            SavedConnection(name: "c", user: "livehub_deploy[y]", connectString: "quoratedb_medium"),
            SavedConnection(name: "d", user: "other", connectString: "roadkitdb_medium"),
        ]
        #expect(Connmgr.matching(all, user: "LIVEHUB_DEPLOY", db: "roadkitdb").map(\.name) == ["a", "b"])
    }
}

@Suite struct SQLclTests {
    @Test func findsFailureLinesAndUsers() {
        let out = """
            Connection failed
              Error Message = ORA-01017: invalid credential
            USER is ""
            A connection named x already exists
            SP2-0640: Not connected
            USER is "RS_SPIKE"
            User altered.
            """
        #expect(SQLcl.failureLines(out).count == 4)
        #expect(SQLcl.showUsers(out) == ["", "RS_SPIKE"])
        #expect(SQLcl.failureLines("User altered.\nConnection Test Successful").isEmpty)
    }

    @Test func buildsCommandsWithQuotedPasswords() {
        #expect(SQLcl.resave(zip: "/t/w.zip", name: "c1", login: "u[s]", password: "Brave.Otter.042", tns: "db_high")
                == "conn -cloudconfig /t/w.zip -save c1 -savepwd -replace u[s]/\"Brave.Otter.042\"@db_high\nshow user")
        #expect(SQLcl.alterUser("U", password: "N.N.001", replacing: "O.O.002")
                == "alter user U identified by \"N.N.001\" replace \"O.O.002\";")
        #expect(SQLcl.prefix.contains("set feedback on"))
    }

    @Test func passesPasswordsOnlyOnStandardInput() throws {
        let h = try Harness()
        let sql = try SQLcl(runner: h.runner, environment: ["PATH": h.root.appendingPathComponent("bin").path,
                                                            "TNS_ADMIN": "/somewhere"])
        _ = try sql.run(SQLcl.connect(zip: "/z.zip", login: "U", password: "Brave.Otter.042", tns: "x_high"),
                        secrets: ["Brave.Otter.042"])
        let call = h.runner.calls.last!
        #expect(call.arguments == ["-S", "/nolog"])
        #expect(call.stdin.contains("Brave.Otter.042"))
        #expect(sql.environment["TNS_ADMIN"] == nil)
    }
}

@Suite struct ScrubTests {
    @Test func masksEverySecret() {
        let text = "conn u/\"Brave.Otter.042\" and Brave.Otter.042 and Quiet.Lake.001"
        let masked = scrub(text, secrets: ["Brave.Otter.042", "Quiet.Lake.001", ""])
        #expect(!masked.contains("Brave") && !masked.contains("Quiet"))
        #expect(masked.components(separatedBy: "********").count == 4)
    }

    @Test func stripsColour() {
        #expect(stripANSI("\u{1B}[0;33mname\u{1B}[0m") == "name")
    }
}

@Suite struct LocalEnvTests {
    @Test func findsTheTestPrincipal() {
        #expect(LocalEnv.testPrincipal("export ROAD_ORDS_HOST=x\n") == "ADMIN")
        #expect(LocalEnv.testPrincipal("# export ROAD_TEST_USERNAME=ALICE\n") == "ADMIN")
        #expect(LocalEnv.testPrincipal("export ROAD_TEST_USERNAME='alice'\n") == "ALICE")
        #expect(LocalEnv.testPrincipal("ROAD_TEST_USERNAME=BOB # note\n") == "BOB")
    }

    @Test func replacesTheLineAndKeepsTheRest() {
        let before = "export ROAD_ORDS_HOST=https://h\nexport ROAD_TEST_PASSWORD='old'\n# tail\n"
        let after = LocalEnv.rewrite(before, password: "Brave.Otter.042")
        #expect(after == "export ROAD_ORDS_HOST=https://h\nexport ROAD_TEST_PASSWORD='Brave.Otter.042'\n# tail\n")
        #expect(LocalEnv.value(of: "ROAD_TEST_PASSWORD", in: after) == "Brave.Otter.042")
    }

    @Test func appendsWhenAbsent() {
        let after = LocalEnv.rewrite("export ROAD_ORDS_HOST=https://h\n", password: "Brave.Otter.042")
        #expect(after == "export ROAD_ORDS_HOST=https://h\nexport ROAD_TEST_PASSWORD='Brave.Otter.042'\n")
    }

    @Test func keepsALineWithoutExport() {
        #expect(LocalEnv.rewrite("ROAD_TEST_PASSWORD=x\n", password: "A.B.001") == "ROAD_TEST_PASSWORD='A.B.001'\n")
    }

    @Test func updatesOnlyForTheNamedPrincipal() throws {
        let h = try Harness()
        let file = h.project.appendingPathComponent("config/local.env")
        #expect(try LocalEnv.update(project: h.project, name: "ADMIN", password: "A.B.001", isIgnored: { _ in true }) == .missing)
        try "export ROAD_TEST_USERNAME=ALICE\nexport ROAD_TEST_PASSWORD='x'\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try LocalEnv.update(project: h.project, name: "ADMIN", password: "A.B.001", isIgnored: { _ in true })
                == .otherPrincipal("ALICE"))
        try "export ROAD_TEST_PASSWORD='x'\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        #expect(throws: RoadError.self) {
            try LocalEnv.update(project: h.project, name: "ADMIN", password: "A.B.001", isIgnored: { _ in false })
        }
        #expect(try LocalEnv.update(project: h.project, name: "ADMIN", password: "A.B.001", isIgnored: { _ in true }) == .updated)
        #expect(try String(contentsOf: file, encoding: .utf8) == "export ROAD_TEST_PASSWORD='A.B.001'\n")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o640)
    }
}

@Suite struct WalletTests {
    @Test func findsAliases() {
        let tns = "roadkitdb_medium = (description=...)\n  roadkitdb_high=(description=...)\n"
        #expect(WalletZip.defines(tns, alias: "roadkitdb_medium"))
        #expect(WalletZip.defines(tns, alias: "ROADKITDB_HIGH"))
        #expect(!WalletZip.defines(tns, alias: "roadkitdb_low"))
        #expect(!WalletZip.defines(tns, alias: "roadkitdb"))
    }

    @Test func zipsADirectoryWithoutSavedCredentials() throws {
        let h = try Harness()
        let zip = try WalletZip.prepare(h.wallet("roadkitdb"), runner: h.runner)
        let call = h.runner.calls.last!
        #expect(call.executable == "/usr/bin/zip")
        #expect(call.arguments.contains { $0.hasSuffix("tnsnames.ora") })
        #expect(!call.arguments.contains { $0.hasSuffix("credentials.sso") })
        let dir = URL(fileURLWithPath: zip.path).deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: zip.path))
        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        zip.remove()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }
}
