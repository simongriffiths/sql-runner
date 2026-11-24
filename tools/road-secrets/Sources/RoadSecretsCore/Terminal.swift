import Foundation
import Darwin

/// Questions asked at the terminal.
public protocol Terminal {
    /// True when standard input is a terminal.
    var isInteractive: Bool { get }
    func confirm(_ question: String) -> Bool
    /// Reads a secret with echo off. Nil if none was entered.
    func readSecret(_ prompt: String) -> String?
}

public struct SystemTerminal: Terminal {
    public init() {}

    public var isInteractive: Bool { isatty(STDIN_FILENO) == 1 }

    public func confirm(_ question: String) -> Bool {
        FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
        guard let answer = readLine() else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }

    public func readSecret(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        guard let result = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else { return nil }
        let value = String(cString: result)
        // Overwrite the buffer once copied.
        for i in buffer.indices { buffer[i] = 0 }
        return value.isEmpty ? nil : value
    }
}
