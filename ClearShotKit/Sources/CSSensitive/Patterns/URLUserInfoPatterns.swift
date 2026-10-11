import Foundation

/// The user info of a URL that has a password: `scheme://user:password@host`.
///
/// A password is never dropped for what it looks like: `localhost:3000?email=jane@…` reads as the user `localhost` and the
/// password `3000?email=jane`, which may be a port and a query, but `redis://:2024#Winter@cache` has the same shape and is a
/// password. Nor does a password hide an address, or an address a password: both are found, each as its own kind, and
/// where they overlap their masks join.
enum URLUserInfoPatterns {
    /// A scheme, `://`, the user and the colon after it, and the rest of the run of text (up to a space), which holds the
    /// password. The user may be empty (`redis://:password@host`), and it may hold an `@`
    /// (`smtp://jane@example.com:secret@host`); it ends at the first colon, and a `/` before that colon means there is no
    /// user info (`https://example.com/a:b@c` and a `host:port/path` without a scheme have none). A scheme is only read from
    /// its start, so each match starts at a scheme.
    ///
    /// The rest of the run is taken possessively, in one go, so the line is read once: a match ends where the run does, and
    /// the next one starts after it. A scheme inside the run is inside the password, or has no `@` after it to end one.
    private static let userAndRestOfRun = NSRegularExpression.fixed(
        #"(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]*+://[^\s/:]*+:(\S*+)"#)

    /// The passwords of the URLs in `line` that have one, in order.
    ///
    /// A password runs from the colon after the user to the **last** `@` before a space, and may hold anything: a `/` (a
    /// generated password often does), a `#`, a `?`, a `:`, an `@` ("P@ssw0rd") and, at its end, an `@` too
    /// (`pw@@host` has the password `pw@`). A password that stopped at the first `@` or at a slash would leave the rest of it
    /// readable. What it costs is a mask over more than the secret when an `@` comes later in the same run of text, in a
    /// path or a query (`https://user:pw@host/a@b` masks `pw@host/a`); a mask may cover a little more than a secret, but
    /// never leave part of one. A run with no `@` after the colon, or only one right after it (`redis://:@host`), has no
    /// password.
    static func passwords(in line: String) -> [Range<String.Index>] {
        userAndRestOfRun.ranges(in: line, group: 1).compactMap { restOfRun in
            guard let lastAt = line.utf16[restOfRun].lastIndex(of: 0x40), lastAt > restOfRun.lowerBound else { return nil }
            return restOfRun.lowerBound..<lastAt
        }
    }
}
