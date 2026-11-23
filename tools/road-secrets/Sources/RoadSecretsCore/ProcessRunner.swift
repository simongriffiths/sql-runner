import Foundation

public struct ProcessResult {
    public let status: Int32
    /// Standard output and standard error together.
    public let output: String
}

/// Runs child processes. Secrets travel only on standard input, never in `arguments`.
public protocol ProcessRunning {
    func run(_ executable: String, _ arguments: [String], stdin: String,
             environment: [String: String]?, directory: URL?) throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], stdin: String,
                    environment: [String: String]?, directory: URL?) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw RoadError(.external, "could not start \(executable): \(error.localizedDescription)")
        }
        // Write in the background so a large output cannot deadlock against a full input pipe.
        let data = Data(stdin.utf8)
        let writer = DispatchQueue(label: "road-secrets.stdin")
        writer.async {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        writer.sync {}
        return ProcessResult(status: process.terminationStatus, output: String(decoding: out, as: UTF8.self))
    }
}

/// Finds an executable on PATH.
public func which(_ name: String, path: String?) -> String? {
    for dir in (path ?? "/usr/bin:/bin").split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
