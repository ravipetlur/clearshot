import CSSensitive
import Foundation

/// What the detector found: the kind and the matched text.
struct Found: Equatable, CustomStringConvertible {
    let kind: SensitiveKind
    let text: String
    init(_ kind: SensitiveKind, _ text: String) {
        self.kind = kind
        self.text = text
    }
    var description: String { "\(kind) \(text)" }
}

/// The detector's findings in `line`, as kinds and the text they cover.
func found(_ line: String, _ kinds: SensitiveKinds = .all) -> [Found] {
    SensitiveDetector.findings(in: line, kinds: kinds).map { Found($0.kind, String(line[$0.range])) }
}

/// The text the detector found in `line` for `kinds`, whatever the kind.
func foundText(_ line: String, _ kinds: SensitiveKinds = .all) -> [String] {
    found(line, kinds).map(\.text)
}

/// The line as it is left on screen once every finding is masked: each finding's text replaced by one `▓`. What is left
/// is what stays readable, so a test that compares it to the line with its secret replaced by `▓` fails if any part of
/// the secret stays outside a finding, or if a finding covers more than the secret.
func masked(_ line: String, _ kinds: SensitiveKinds = .all) -> String {
    var result = ""
    var cursor = line.startIndex
    for finding in SensitiveDetector.findings(in: line, kinds: kinds) {
        result += line[cursor..<finding.range.lowerBound]
        result += "▓"
        cursor = finding.range.upperBound
    }
    return result + line[cursor...]
}

/// What of `secret` stays readable in `line` once every finding is masked: the characters of each place it is written that
/// no finding covers. Empty when every one is masked whole, whatever else the masks take in (where a mask may cover more
/// than the secret, a test asks this rather than compare `masked`).
func readable(_ secret: String, in line: String, _ kinds: SensitiveKinds = .all) -> String {
    let findings = SensitiveDetector.findings(in: line, kinds: kinds)
    var left = ""
    var from = line.startIndex
    var seen = false
    while let place = line.range(of: secret, options: .literal, range: from..<line.endIndex) {
        seen = true
        var index = place.lowerBound
        while index < place.upperBound {
            if !findings.contains(where: { $0.range.contains(index) }) { left.append(line[index]) }
            index = line.index(after: index)
        }
        from = place.upperBound
    }
    return seen ? left : "(\(secret) is not in the line)"
}

/// The pieces joined: a literal built from parts, so no file holds the whole of a realistic-looking one. (A run of `+`
/// in an array literal is too much for the compiler.)
func parts(_ pieces: String...) -> String { pieces.joined() }

/// Synthetic values. Nothing here is a real key, number or address, and the fake keys are built from parts, so no file
/// holds a realistic-looking one.
enum Fake {
    /// Letters of both cases and digits, with `0` and `1` among them.
    static let mixed = "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz"
    /// Capitals and digits, as an AWS key id uses, with `0` and `1` among the first 16.
    static let capitals = "A7B0CDEF1GHJKLMNPQRSTUVWXYZ2345689"

    /// `count` characters, cycling through `alphabet`.
    static func chars(_ count: Int, from alphabet: String = mixed) -> String {
        let letters = Array(alphabet)
        return String((0..<count).map { letters[$0 % letters.count] })
    }

    /// `ghp_`, `gho_`... and 36 characters.
    static func github(_ letter: Character = "p", body: Int = 36) -> String { "gh" + String(letter) + "_" + chars(body) }
    static func githubFineGrained(body: Int = 30) -> String { "github" + "_pat_" + chars(body) }
    static func aws(_ prefix: String = "AKIA", body: Int = 16) -> String { prefix + chars(body, from: capitals) }
    static func stripe(_ prefix: String = "sk_live_", body: Int = 24) -> String { prefix + chars(body) }
    static func slack(_ letter: Character = "b") -> String { "xox" + String(letter) + "-" + chars(10, from: "1234567890") + "-" + chars(24) }
    static func google(body: Int = 35) -> String { "AI" + "za" + chars(body) }
    /// Three dot-separated parts, the first two starting `eyJ` as a JWT's JSON does.
    static func jwt() -> String { "ey" + "J" + chars(16) + "." + "ey" + "J" + chars(24) + "." + chars(32) }
    /// A JWT's header and payload, each starting `eyJ`.
    static func jwtHeader() -> String { "ey" + "J" + chars(16) }
    static func jwtPayload(_ body: Int = 24) -> String { "ey" + "J" + chars(body) }
    /// The first line of a private-key block, built from parts: `dashes`, BEGIN, the kind of key (none: "PRIVATE KEY"
    /// alone), and the dashes again.
    static func privateKeyBegin(_ kind: String = "RSA", dashes: String = "-----") -> String {
        dashes + "BEGIN " + (kind.isEmpty ? "" : kind + " ") + "PRIVATE" + " KEY" + dashes
    }
    /// The last line of the block.
    static func privateKeyEnd(_ kind: String = "RSA", dashes: String = "-----") -> String {
        dashes + "END " + (kind.isEmpty ? "" : kind + " ") + "PRIVATE" + " KEY" + dashes
    }
    /// A line of a private key's body: base64, 64 characters, with `+` and `/` among them. `line` shifts where in the
    /// alphabet it starts, so the lines of one key differ.
    static func privateKeyBody(_ count: Int = 64, line: Int = 0) -> String {
        chars(count, from: String(base64.dropFirst(line % base64.count)) + String(base64.prefix(line % base64.count)))
    }
    /// A private key written on one line, as JSON and `.env` files write it: the lines of the key joined by a literal
    /// backslash and `n` (two characters, not a newline). `lines` lines of 64 characters, and the END line after them if
    /// `withEnd`, and a trailing `\n`.
    static func escapedPrivateKey(_ kind: String = "", lines: Int = 26, withEnd: Bool = true) -> String {
        let body = (0..<lines).map { privateKeyBody(64, line: $0) }
        let end = withEnd ? ["\\n", privateKeyEnd(kind), "\\n"] : []
        return privateKeyBegin(kind) + "\\n" + body.joined(separator: "\\n") + end.joined()
    }
    /// Letters of both cases, digits, `+` and `/`.
    static let base64 = "aB3dE5fG7hJ9kL1mN2pQ4rS6tU8vW0xYz+Ab/Cd"
    static func secretKey(body: Int = 24) -> String { "sk" + "-" + chars(body) }

    /// A card number: `prefix` and the check digit that makes it pass the Luhn check, `length` digits in all.
    static func cardDigits(prefix: String, length: Int) -> String {
        let body = prefix + String(repeating: "0", count: length - prefix.count - 1)
        for check in 0...9 {
            let candidate = body + String(check)
            if luhnHolds(candidate) { return candidate }
        }
        preconditionFailure("every digit string has a check digit")
    }

    /// The Luhn check, written out independently of the detector's.
    static func luhnHolds(_ digits: String) -> Bool {
        var sum = 0
        for (index, character) in digits.reversed().enumerated() {
            var value = character.wholeNumberValue ?? 0
            if index % 2 == 1 {
                value *= 2
                if value > 9 { value -= 9 }
            }
            sum += value
        }
        return sum % 10 == 0
    }
}
