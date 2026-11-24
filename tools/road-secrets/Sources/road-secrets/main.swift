import AppKit
import Foundation
import RoadSecretsCore

// Entry point. All behaviour is in RoadSecretsCore; this file only wires in the real Keychain,
// processes, terminal, network and clipboard.

let runner = SystemProcessRunner()
let dependencies = Dependencies(
    store: LoginKeychain(),
    runner: runner,
    terminal: SystemTerminal(),
    login: URLSessionLogin(),
    generator: PasswordGenerator(),
    environment: ProcessInfo.processInfo.environment,
    home: FileManager.default.homeDirectoryForCurrentUser,
    currentDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    now: { Date() },
    out: { print($0) },
    err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
    copyToClipboard: { value in
        let board = NSPasteboard.general
        board.clearContents()
        return board.setString(value, forType: .string)
    },
    isLocalEnvIgnored: Dependencies.gitIgnored(runner: runner),
    gitRoot: Dependencies.gitRoot(runner: runner)
)

exit(App(dependencies).main(Array(CommandLine.arguments.dropFirst())))
