import Foundation
import Security

/// A source of uniform random integers.
public protocol RandomSource {
    /// A uniformly distributed integer in 0..<upperBound.
    func uniform(_ upperBound: Int) -> Int
}

/// `SecRandomCopyBytes`, with rejection sampling so that every value is equally likely.
public struct SecureRandom: RandomSource {
    public init() {}

    public func uniform(_ upperBound: Int) -> Int {
        precondition(upperBound > 0 && upperBound <= Int(UInt32.max))
        let bound = UInt32(upperBound)
        let limit = UInt32.max - (UInt32.max % bound)
        while true {
            var value: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &value) { buffer in
                SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
            }
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
            if value < limit { return Int(value % bound) }
        }
    }
}

/// Generates `Adjective.Noun.nnn` passwords (spec Section 6).
public struct PasswordGenerator {
    public let adjectives: [String]
    public let nouns: [String]
    let random: RandomSource

    public init(adjectives: [String] = WordLists.adjectives,
                nouns: [String] = WordLists.nouns,
                random: RandomSource = SecureRandom()) {
        precondition(!adjectives.isEmpty && !nouns.isEmpty)
        self.adjectives = adjectives
        self.nouns = nouns
        self.random = random
    }

    /// A new password that does not contain any of `avoiding`, ignoring case (Section 6.1).
    public func generate(avoiding: [String] = []) -> String {
        let banned = avoiding.map { $0.lowercased() }.filter { !$0.isEmpty }
        while true {
            let adjective = Self.capitalised(adjectives[random.uniform(adjectives.count)])
            let noun = Self.capitalised(nouns[random.uniform(nouns.count)])
            let number = String(format: "%03d", random.uniform(1000))
            let password = "\(adjective).\(noun).\(number)"
            let lowered = password.lowercased()
            if !banned.contains(where: { lowered.contains($0) }) { return password }
        }
    }

    static func capitalised(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst().lowercased()
    }

    /// A word list entry is valid if it has 4 to 8 letters, all lowercase ASCII (Section 6.2).
    public static func isValidWord(_ word: String) -> Bool {
        (4...8).contains(word.count) && word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
    }
}
