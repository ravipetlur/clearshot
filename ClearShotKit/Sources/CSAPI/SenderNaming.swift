import Foundation
import Security

/// Who sent a URL, read once at receipt (the receiver's Apple-event handler): nothing resolves the PID later, because
/// `/usr/bin/open` and the like have exited by then.
public struct SenderFacts: Sendable, Equatable {
    /// From the walk up the parents (`SenderNaming`), for the log only: `name` may be a parent app's, and any app can take
    /// any name and bundle ID. `name` nil: nothing named it (it has exited, or it is ClearShot forwarding a command).
    public let pid: Int32?, bundleID: String?, name: String?
    /// The event's `audit_token_t`: `pid` is its PID (`SenderPID`), and `verified` is read through it. Trust uses the
    /// PID only (`URLConsent.decide`).
    public let auditToken: Data?
    /// The sending process itself, as its verified code signature says; nil when it couldn't be verified. The only
    /// identity ClearShot shows (`URLConsent.describe`).
    public let verified: VerifiedSender?

    public init(pid: Int32?, bundleID: String?, name: String?, auditToken: Data?, verified: VerifiedSender? = nil) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.auditToken = auditToken
        self.verified = verified
    }
}

/// The PID of a URL's sender, as trust (`URLConsent.decide`) and naming use it: the one in the event's audit token,
/// which the kernel fills in for the sending process, never `keySenderPIDAttr` alone.
public enum SenderPID {
    /// The token's PID, as libbsm's `audit_token_to_pid` reads it (the sixth of its eight words); nil unless `token` is
    /// an `audit_token_t`.
    public static func inAuditToken(_ token: Data?) -> Int32? {
        guard let token, token.count == MemoryLayout<audit_token_t>.size else { return nil }
        let value = token.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        return Int32(bitPattern: value.val.5)
    }

    /// The audit token's PID; nil (an unknown sender, asked like any other) without a token, or when the event's own
    /// PID attribute disagrees with it.
    public static func of(eventPID: Int32?, auditToken: Data?) -> Int32? {
        guard let pid = inAuditToken(auditToken), eventPID.map({ $0 == pid }) ?? true else { return nil }
        return pid
    }
}

/// The process that sent a URL, as its code signature says. The app reads it at receipt from the event's audit token,
/// and only when the signature checks out: valid, and either Apple's own or signed for distribution (Developer ID or
/// the Mac App Store; `developerRequirement`). A bundle ID or a name alone is the sender's own claim; signed for
/// distribution, it is the team's.
public struct VerifiedSender: Sendable, Equatable {
    public enum Signer: Sendable, Equatable {
        /// Apple's own code (`anchor apple`).
        case apple
        /// A developer team's, by its team ID: a Developer ID or Mac App Store signature (`developerRequirement`).
        case team(String)
    }

    /// The signing identifier: an app's bundle ID, or a tool's own identifier.
    public let identifier: String
    public let signer: Signer
    /// Its own name from its signed Info.plist; nil when it has none (most tools). Never a file name or a parent's.
    public let name: String?

    public init(identifier: String, signer: Signer, name: String?) {
        self.identifier = identifier
        self.signer = signer
        self.name = name
    }

    /// The sender as `SecCodeCopySigningInformation` describes it (`info`), once the app has checked its signature
    /// meets `signer`'s requirement. Only what the signature seals counts: the signing identifier, and a name from the
    /// signed Info.plist, its display name else its bundle name. A file name isn't sealed (a renamed copy of a tool
    /// keeps its signature), so a tool without a signed name has none. Nil without a signing identifier.
    public init?(signingInformation info: [String: Any], signer: Signer) {
        guard let identifier = info[kSecCodeInfoIdentifier as String] as? String else { return nil }
        let plist = info[kSecCodeInfoPList as String] as? [String: Any]
        self.init(identifier: identifier, signer: signer,
                  name: plist?["CFBundleDisplayName"] as? String ?? plist?["CFBundleName"] as? String)
    }

    /// The code requirement for `.apple`: Apple's own code, its apps and its platform tools.
    public static let appleRequirement = "anchor apple"

    /// The code requirement for `.team(team)`: signed for distribution, which is a Mac App Store signature, or a
    /// Developer ID Application certificate issued to `team`. A development certificate, which any Apple ID can get and
    /// use to sign any name and bundle ID, doesn't verify. Nil when `team` isn't shaped like a team ID (`isTeamID`), so
    /// nothing can be added to the requirement.
    public static func developerRequirement(team: String) -> String? {
        guard isTeamID(team) else { return nil }
        let appStore = "certificate leaf[field.1.2.840.113635.100.6.1.9]"
        let developerID = "certificate 1[field.1.2.840.113635.100.6.2.6] and "
            + "certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
        return "anchor apple generic and (\(appStore) or (\(developerID)))"
    }

    /// Whether `text` is shaped like a team ID: ten uppercase ASCII letters or digits. The app puts it into a code
    /// requirement, so nothing else may reach it.
    public static func isTeamID(_ text: String) -> Bool {
        text.utf8.count == 10 && text.utf8.allSatisfy { (0x30 ... 0x39).contains($0) || (0x41 ... 0x5A).contains($0) }
    }
}

/// What a sender chose to call itself, as ClearShot shows or logs it: on one line, in its own order, without invisible
/// characters, and at most `APIRequest.shownNameLimit` characters.
public enum SenderText {
    /// The most combining marks kept on one character.
    public static let markLimit = 2
    /// The most Unicode scalars a name shows, after the 40-character cap: characters that join into one grapheme
    /// (prepend characters, Hangul jamo, emoji modifiers) could otherwise carry thousands.
    public static let scalarLimit = 80

    /// A name, sanitised:
    /// - format characters (bidirectional controls and isolates, zero-width characters, tags) and invisible fillers are
    ///   removed;
    /// - line breaks and other control characters become spaces;
    /// - at most `markLimit` combining marks stay on a character (a dropped filler doesn't start a new count);
    /// - it is trimmed, and nil when nothing is left;
    /// - then it is cut to 40 characters (grapheme clusters), the last an ellipsis, and then to `scalarLimit` Unicode
    ///   scalars, likewise.
    public static func name(_ text: String?) -> String? {
        guard let text else { return nil }
        var kept = String.UnicodeScalarView()
        var marks = 0
        for scalar in text.unicodeScalars {
            let category = scalar.properties.generalCategory
            switch category {
            case .format:
                continue
            case .control, .lineSeparator, .paragraphSeparator:
                kept.append(" ")
                marks = 0
            case .nonspacingMark, .spacingMark, .enclosingMark:
                marks += 1
                if marks <= markLimit { kept.append(scalar) }
            default:
                // A dropped character leaves the marks counting: only a character that is kept starts a new count.
                // Dropped: the fillers, anything default-ignorable, and unassigned code points, which all draw nothing.
                let properties = scalar.properties
                guard !invisible.contains(scalar.value), !properties.isDefaultIgnorableCodePoint,
                      properties.generalCategory != .unassigned else { continue }
                marks = 0
                kept.append(scalar)
            }
        }
        let trimmed = String(kept).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let shortened = APIRequest.shortened(trimmed)
        guard shortened.unicodeScalars.count > scalarLimit else { return shortened }
        return String(String.UnicodeScalarView(shortened.unicodeScalars.prefix(scalarLimit - 1))) + "…"
    }

    /// Other text from outside as a message shows it: a URL's action or path, the name of a file a URL names. As `name`
    /// shows it, or percent-escaped (`code`) when nothing visible is left.
    public static func shown(_ text: String) -> String {
        name(text) ?? code(text)
    }

    /// An identifier (a bundle ID, a team ID): ASCII letters, digits, dots and hyphens as they are, anything else
    /// percent-escaped, then cut to 40 characters.
    public static func code(_ text: String) -> String {
        APIRequest.shortened(text.addingPercentEncoding(withAllowedCharacters: plain) ?? "")
    }

    /// Letters that draw nothing: the Hangul fillers and the blank Braille pattern.
    private static let invisible: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800]

    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
}

/// One running process as the app reads it (`NSRunningApplication`, `sysctl KERN_PROC_PID`).
public struct ProcessFacts: Sendable, Equatable {
    public let parentPID: Int32?, bundleID: String?, name: String?

    public init(parentPID: Int32?, bundleID: String?, name: String?) {
        self.parentPID = parentPID
        self.bundleID = bundleID
        self.name = name
    }
}

/// Names a URL's sender by the first app at or above its process: Raycast names itself, a script run in Terminal is
/// named "Terminal".
public enum SenderNaming {
    /// The most processes the walk looks at, the sender first.
    public static let maximumDepth = 16

    /// Walks `lookup` from `pid` up the parents to the first process with a bundle ID and takes its bundle ID and name.
    /// It never looks up launchd (PID 1), stops at a nil parent, and looks at most `maximumDepth` processes. A process
    /// `lookup` doesn't know (it has exited) leaves the sender unnamed. So does finding ClearShot itself
    /// (`ownBundleID`): a command forwarded by a second copy, whose original sender can't be known.
    ///
    /// `verified` is the sending process's own verified signature, which the facts keep; the walk's name never stands in
    /// for it. A ClearShot signature (a second copy forwarding) is dropped, for the same reason as its name.
    public static func facts(pid: Int32?, auditToken: Data?, ownBundleID: String, verified: VerifiedSender? = nil,
                             lookup: (Int32) -> ProcessFacts?) -> SenderFacts {
        let verified = verified?.identifier == ownBundleID ? nil : verified
        var current = pid
        for _ in 0 ..< maximumDepth {
            guard let process = current, process > 1, let facts = lookup(process) else { break }
            if let bundleID = facts.bundleID {
                let name = bundleID == ownBundleID ? nil : facts.name
                return SenderFacts(pid: pid, bundleID: bundleID, name: name, auditToken: auditToken, verified: verified)
            }
            current = facts.parentPID
        }
        return SenderFacts(pid: pid, bundleID: nil, name: nil, auditToken: auditToken, verified: verified)
    }
}
