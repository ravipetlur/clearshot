import Foundation

/// Keys and tokens: the formats of well-known public tokens, private-key blocks, the names of key files, and the values of
/// labelled secrets ("password: …").
///
/// OCR confuses `O` with `0`, `l` with `1` and `I` with `l`. A token's body takes any letter or digit, so those
/// confusions inside a body change nothing: the token is found whole. The fixed parts (`ghp_`, `AKIA`) are matched as
/// written. A private-key header is found by its words (`PrivateKeyBlockPatterns`), and its dashes may be of any width,
/// or lost.
enum KeyAndTokenPatterns {
    static func spans(in line: String) -> [Range<String.Index>] {
        tokenFormats.flatMap { $0.ranges(in: line) }
            + PrivateKeyBlockPatterns.spans(in: line)
            + bearerTokens.ranges(in: line, group: 1)
            + URLUserInfoPatterns.passwords(in: line)
            + keyFileNames.ranges(in: line)
            + sshKeyFileNames.ranges(in: line)
            + LabelledSecretPatterns.values(in: line)
    }

    // MARK: Token formats

    /// Each is anchored so it doesn't start in the middle of a word ("risk-…" holds `sk-…`).
    private static let tokenFormats: [NSRegularExpression] = [
        // GitHub: `ghp_` `gho_` `ghu_` `ghs_` `ghr_` and 36 letters and digits or more; and the fine-grained `github_pat_`.
        #"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{36,}"#,
        #"(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{22,}"#,
        // AWS access key ids: `AKIA` or `ASIA` and 16 capitals and digits.
        #"(?<![A-Za-z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"#,
        // Stripe: `sk_live_` `sk_test_` `rk_live_` (and `rk_test_`) and 16 letters and digits or more.
        #"(?<![A-Za-z0-9])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#,
        // Slack: `xoxa-` `xoxb-` `xoxp-` `xoxr-` `xoxs-` and the token's groups.
        #"(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9-]{10,}"#,
        // Google API keys: `AIza` and 35 letters, digits, `_` and `-`, or more.
        #"(?<![A-Za-z0-9])AIza[A-Za-z0-9_-]{35,}"#,
        // JSON web tokens: a header and a payload that start `eyJ` (`{"` in base64) and, if there is one, a signature. A
        // token read from a screenshot is often wrapped, cut off in its payload, or has no signature.
        #"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]*)?"#,
        // Generic secret keys of several API providers: `sk-` and 20 letters, digits, `_` and `-` or more.
        #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}"#,
    ].map { NSRegularExpression.fixed($0) }

    // MARK: Bearer tokens

    /// `Bearer`, then at least 16 characters up to the next space, whatever they are. Only the token is the finding. (A
    /// token that stopped at a character an OAuth token doesn't use would leave the rest of it readable.)
    private static let bearerTokens = NSRegularExpression.fixed(#"(?<![A-Za-z0-9])Bearer\s++(\S{16,})"#, caseInsensitive: true)

    // MARK: Key file names

    /// A name that ends `.p8`, `.p12`, `.pfx`, `.pem` or `.key`, with a stem, and whatever case. Without the stem, ".pem" is a
    /// mention of the kind of file, not a file. A dotfile's leading dots are part of the name. It is only tried from the
    /// start of a run of name characters, so a long run is read once.
    private static let keyFileNames = NSRegularExpression.fixed(
        #"(?<![\p{L}\p{N}_.\-])[.\-]*+[\p{L}\p{N}_][\p{L}\p{N}_.\-]*\.(?:p8|p12|pfx|pem|key)(?![\p{L}\p{N}_])"#,
        caseInsensitive: true)

    /// The names ssh gives a private key: `id_rsa`, `id_dsa`, `id_ecdsa` and `id_ed25519`, but not the `.pub` beside it,
    /// which is the public half.
    private static let sshKeyFileNames = NSRegularExpression.fixed(
        #"(?<![\p{L}\p{N}_])id_(?:rsa|dsa|ecdsa|ed25519)(?![\p{L}\p{N}_])(?!\.pub)"#, caseInsensitive: true)
}
