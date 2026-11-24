import Foundation

/// Replaces every occurrence of each secret with `********` (spec Section 8).
public func scrub(_ text: String, secrets: [String]) -> String {
    var result = text
    // Longest first, so that a secret containing another is masked whole.
    for secret in secrets.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
        result = result.replacingOccurrences(of: secret, with: "********")
    }
    return result
}

/// Removes ANSI colour codes, which SQLcl writes even when its output is a pipe.
public func stripANSI(_ text: String) -> String {
    var out = ""
    var iterator = text.unicodeScalars.makeIterator()
    while let c = iterator.next() {
        if c == "\u{1B}" {
            // Skip "[" and parameters up to the final letter.
            while let d = iterator.next() {
                if ("A"..."Z").contains(d) || ("a"..."z").contains(d) { break }
            }
        } else {
            out.unicodeScalars.append(c)
        }
    }
    return out
}
