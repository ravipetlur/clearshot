import Foundation

/// The user info of a URL that has a password: `scheme://user:password@host`.
///
/// A password is never dropped for what it looks like: `localhost:3000?email=jane@…` reads as the user `localhost` and the
/// password `3000?email=jane`, which may be a port and a query, but `redis://:2024#Winter@cache` has the same shape and is a
/// password. Nor does a password hide an address, or an address a password: both are found, each as its own kind, and
/// where they overlap their masks join.
enum URLUserInfoPatterns {
    /// The user (possibly empty: `redis://:password@host`; and it may hold an `@`: `smtp://jane@example.com:secret@host`), up
    /// to the first colon, and the password after it, up to the **last** `@` before a space or a `/`: a raw `@` in a
    /// password is common ("P@ssw0rd"), and a password that stops at the first one leaves the rest of it readable. A scheme
    /// is only read from its start, so each match starts at a scheme and a line of them is read once.
    private static let regex = NSRegularExpression.fixed(
        #"(?<![A-Za-z0-9+.\-])[A-Za-z][A-Za-z0-9+.\-]*+://[^\s/:]*+:([^\s/]+)@"#)

    /// The passwords of the URLs in `line` that have one, in order.
    static func passwords(in line: String) -> [Range<String.Index>] {
        regex.ranges(in: line, group: 1)
    }
}
