import Foundation

/// `config/local.env` handling (spec Section 7.11).
public enum LocalEnv {
    public enum Outcome: Equatable {
        case missing
        case otherPrincipal(String)
        case updated
    }

    /// The test principal: `ROAD_TEST_USERNAME`, or `ADMIN` when unset or commented out.
    public static func testPrincipal(_ text: String) -> String {
        if let value = value(of: "ROAD_TEST_USERNAME", in: text), !value.isEmpty {
            return value.uppercased()
        }
        return "ADMIN"
    }

    /// The value of an uncommented `[export ]NAME=value` line, unquoted.
    public static func value(of name: String, in text: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            guard let rhs = assignment(String(raw), name) else { continue }
            return unquote(rhs)
        }
        return nil
    }

    /// Replaces the `ROAD_TEST_PASSWORD` line, keeping its `export` prefix, or appends one.
    /// The format guarantees the password has no single quote (Section 6.3).
    public static func rewrite(_ text: String, password: String) -> String {
        precondition(!password.contains("'"))
        var lines = text.components(separatedBy: "\n")
        var replaced = false
        for (i, line) in lines.enumerated() where assignment(line, "ROAD_TEST_PASSWORD") != nil {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let export = trimmed.hasPrefix("export ") ? "export " : ""
            lines[i] = "\(export)ROAD_TEST_PASSWORD='\(password)'"
            replaced = true
            break
        }
        if !replaced {
            if lines.last == "" { lines.removeLast() }
            lines.append("export ROAD_TEST_PASSWORD='\(password)'")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func assignment(_ line: String, _ name: String) -> String? {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#") { return nil }
        if t.hasPrefix("export ") { t = String(t.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
        guard t.hasPrefix(name + "=") else { return nil }
        return String(t.dropFirst(name.count + 1))
    }

    static func unquote(_ raw: String) -> String {
        let v = raw.trimmingCharacters(in: .whitespaces)
        for q in ["'", "\""] where v.hasPrefix(q) {
            let body = v.dropFirst()
            if let end = body.firstIndex(of: Character(q)) { return String(body[..<end]) }
            return String(body)
        }
        let token = v.prefix { $0 != " " && $0 != "\t" && $0 != "#" }
        return String(token)
    }

    /// Writes the password into `<project>/config/local.env` if that file names `name` as its test
    /// principal. Refuses (exit 5) if git does not ignore the file.
    public static func update(project: URL, name: String, password: String,
                              isIgnored: (URL) -> Bool) throws -> Outcome {
        let file = project.appendingPathComponent("config/local.env")
        let fm = FileManager.default
        guard fm.fileExists(atPath: file.path) else { return .missing }
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw RoadError(.external, "cannot read \(file.path)")
        }
        let principal = testPrincipal(text)
        guard principal == name else { return .otherPrincipal(principal) }
        guard isIgnored(project) else {
            throw RoadError(.external,
                "refused to write \(file.path): git does not ignore it (D-03). Add config/local.env to .gitignore.")
        }
        let updated = rewrite(text, password: password)
        let attributes = try? fm.attributesOfItem(atPath: file.path)
        let temp = file.deletingLastPathComponent().appendingPathComponent(".local.env.road-secrets.\(UUID().uuidString)")
        do {
            fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try Data(updated.utf8).write(to: temp)
            if let mode = attributes?[.posixPermissions] {
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
            }
            guard rename(temp.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? fm.removeItem(at: temp)
            throw RoadError(.external, "could not write \(file.path)")
        }
        return .updated
    }
}
