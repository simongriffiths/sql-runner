import Foundation
import Darwin

/// Questions asked at the terminal.
public protocol Terminal {
    /// True when standard input is a terminal.
    var isInteractive: Bool { get }
    func confirm(_ question: String) -> Bool
    /// Reads one line from standard input with no prompt, and with echo off when standard input
    /// is a terminal, so a password can be piped in. Nil if standard input is empty.
    func readStandardInputSecret() -> String?
}

public struct SystemTerminal: Terminal {
    public init() {}

    public var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    public func confirm(_ question: String) -> Bool {
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine() else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public func readStandardInputSecret() -> String? {
        if isInteractive {
            var buffer = [CChar](repeating: 0, count: 512)
            guard let result = readpassphrase("", &buffer, buffer.count, RPP_REQUIRE_TTY) else { return nil }
            let value = String(cString: result)
            for i in buffer.indices { buffer[i] = 0 }
            return value.isEmpty ? nil : value
        }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else { return nil }
        return line
    }
}
