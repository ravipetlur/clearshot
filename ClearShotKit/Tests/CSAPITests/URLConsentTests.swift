import Foundation
import Testing
@testable import CSAPI

/// The keys of `SecCodeCopySigningInformation`'s dictionary (`kSecCodeInfoIdentifier`, `kSecCodeInfoPList`,
/// `kSecCodeInfoMainExecutable`), spelled out so the tests needn't import Security.
enum SigningKey {
    static let identifier = "identifier", plist = "info-plist", mainExecutable = "main-executable"
}

struct URLConsentTests {
    let ownPID: Int32 = 123
    let raycast = SenderFacts(pid: 500, bundleID: "com.raycast.macos", name: "Raycast", auditToken: nil)
    let exited = SenderFacts(pid: 501, bundleID: nil, name: nil, auditToken: nil)

    func decide(_ sender: SenderFacts, allows: Bool, granted: Bool) -> URLConsent.Decision {
        URLConsent.decide(allowsAPI: allows, granted: granted, sender: sender, ownPID: ownPID)
    }

    @Test func theDecisionTable() {
        let table: [(allows: Bool, granted: Bool, decision: URLConsent.Decision)] = [
            (true, false, .ask), (true, true, .run), (false, false, .drop), (false, true, .drop),
        ]
        for row in table {
            #expect(decide(raycast, allows: row.allows, granted: row.granted) == row.decision, "\(row)")
            #expect(decide(exited, allows: row.allows, granted: row.granted) == row.decision, "\(row)")
        }
    }

    @Test func ourOwnProcessRunsEvenWithTheAPIOff() {
        let us = SenderFacts(pid: ownPID, bundleID: "test.clearshot", name: nil, auditToken: nil)
        let unnamedUs = SenderFacts(pid: ownPID, bundleID: nil, name: nil, auditToken: nil)
        for allows in [true, false] {
            for granted in [true, false] {
                #expect(decide(us, allows: allows, granted: granted) == .run)
                #expect(decide(unnamedUs, allows: allows, granted: granted) == .run)
            }
        }
    }

    /// Only our own PID is trusted; the bundle ID never counts, so another ClearShot (a second copy forwarding, or one
    /// pretending) is treated like any other app.
    @Test func anotherClearShotProcessIsNeverTrusted() {
        let copy = SenderFacts(pid: 999, bundleID: "test.clearshot", name: nil, auditToken: nil)
        #expect(decide(copy, allows: true, granted: true) == .run)
        #expect(decide(copy, allows: true, granted: false) == .ask)
        #expect(decide(copy, allows: false, granted: true) == .drop)
        #expect(decide(copy, allows: false, granted: false) == .drop)
        // No PID at all is never ours.
        let nobody = SenderFacts(pid: nil, bundleID: nil, name: nil, auditToken: nil)
        #expect(decide(nobody, allows: true, granted: false) == .ask)
        #expect(decide(nobody, allows: false, granted: true) == .drop)
    }

    /// The prompt's question, and the plain statement that Allow covers every app and lets them open files
    /// (`filepath`).
    let question = "Do you want to let other apps control ClearShot? "
        + "Allowing lets any app on this Mac run ClearShot commands, capture your screen and open your image and video "
        + "files."

    func signed(_ name: String?, _ identifier: String, _ signer: VerifiedSender.Signer) -> SenderFacts {
        SenderFacts(pid: 500, bundleID: identifier, name: name, auditToken: nil,
                    verified: VerifiedSender(identifier: identifier, signer: signer, name: name))
    }

    @Test func stringsAreTheDecidedOnes() {
        let named = URLConsent.prompt(command: "capture-area", sender: signed("Raycast", "com.raycast.macos",
                                                                               .team("SY64MV22J9")))
        #expect(named.title == "Another app wants to control ClearShot")
        #expect(named.message == "ClearShot received a command from Raycast (com.raycast.macos, team "
            + "SY64MV22J9): capture-area. \(question)")
        let unnamed = URLConsent.prompt(command: "pin", sender: exited)
        #expect(unnamed.title == "Another app wants to control ClearShot")
        #expect(unnamed.message == "ClearShot received a command from an external app: pin. \(question)")
        #expect(URLConsent.allowButton == "Allow")
        #expect(URLConsent.dontAllowButton == "Don't Allow")
        #expect(URLConsent.offNotice == "URL commands are off (Settings › Advanced)")
    }

    /// The command name stays percent-encoded and whole for the log; the prompt shows at most 40 characters of it, so a
    /// long URL can't fill the alert.
    @Test func thePromptShortensALongCommandName() {
        let forty = String(repeating: "b", count: 40)
        #expect(URLConsent.prompt(command: forty, sender: exited).message
            == "ClearShot received a command from an external app: \(forty). \(question)")
        let long = String(repeating: "a", count: 41)
        #expect(URLConsent.prompt(command: long, sender: exited).message
            == "ClearShot received a command from an external app: "
            + "\(String(repeating: "a", count: 39))…. \(question)")
    }

    /// A name and a bundle ID are both the sender's own claims. The sender is named only by its own verified code
    /// signature, read from the event's audit token: "Name (bundle ID, team TEAMID)", or "Apple" for Apple's code. A
    /// name found by walking up to a parent app, or a sender whose signature can't be verified, is "an unverified app";
    /// with nothing known at all (it has exited, or a second ClearShot forwarded the command), "an external app".
    @Test func onlyAVerifiedSenderIsNamed() {
        #expect(URLConsent.describe(signed("Raycast", "com.raycast.macos", .team("SY64MV22J9")))
            == "Raycast (com.raycast.macos, team SY64MV22J9)")
        // The signed identifier always shows beside a name, Apple's code included.
        #expect(URLConsent.describe(signed("Terminal", "com.apple.Terminal", .apple))
            == "Terminal (com.apple.Terminal, Apple)")
        // Without a signed name, its signing identifier names it.
        #expect(URLConsent.describe(signed(nil, "com.apple.osascript", .apple)) == "com.apple.osascript (Apple)")
        #expect(URLConsent.describe(signed("\u{200B}", "com.example.tool", .team("ABCDE12345")))
            == "com.example.tool (team ABCDE12345)")
        // Named by walking (a script in Terminal), or by an unverified app: never shown as who it is.
        #expect(URLConsent.describe(raycast) == "an unverified app")
        let underTerminal = SenderFacts(pid: 30, bundleID: "com.apple.Terminal", name: "Terminal", auditToken: nil)
        #expect(URLConsent.describe(underTerminal) == "an unverified app")
        // Nothing known.
        #expect(URLConsent.describe(exited) == "an external app")
        let forwarded = SenderFacts(pid: 999, bundleID: "test.clearshot", name: nil, auditToken: nil)
        #expect(URLConsent.describe(forwarded) == "an external app")
        #expect(URLConsent.prompt(command: "pin", sender: raycast).message
            == "ClearShot received a command from an unverified app: pin. \(question)")
    }

    /// The capture notice says who is capturing with the same label the prompt and the log use.
    @Test func theCaptureNoticeUsesTheSameLabel() {
        #expect(URLConsent.captureNotice(sender: signed("Raycast", "com.raycast.macos", .team("SY64MV22J9")))
            == "Raycast (com.raycast.macos, team SY64MV22J9) is capturing your screen with ClearShot")
        #expect(URLConsent.captureNotice(sender: raycast) == "An unverified app is capturing your screen with ClearShot")
        #expect(URLConsent.captureNotice(sender: exited) == "Another app is capturing your screen with ClearShot")
    }

    /// A verified sender's name is still the developer's to choose: it can't break the prompt onto new lines, reorder it,
    /// hide in invisible characters, stack marks over the alert or fill it.
    @Test func aVerifiedNameCantReshapeThePrompt() {
        let sender = signed("Raycast\u{2028}ClearShot needs this", "com.evil.app", .team("ABCDE12345"))
        #expect(URLConsent.describe(sender) == "Raycast ClearShot needs this (com.evil.app, team ABCDE12345)")
        let reversed = signed("Ray\u{202E}tsacyaR", "com.evil\u{200F}.app", .team("ABCDE12345"))
        #expect(URLConsent.describe(reversed) == "RaytsacyaR (com.evil%E2%80%8F.app, team ABCDE12345)")
    }

    /// What a sender shows, sanitised. Format characters (bidi controls and isolates, zero-width characters) and
    /// invisible fillers are removed; line breaks and other controls become spaces; at most two combining marks stay on
    /// a character; the result is trimmed, empty is no name, and it is cut to 40 characters (grapheme clusters) after
    /// all that.
    @Test func aSendersNameIsSanitised() {
        #expect(SenderText.name("Raycast\u{2028}Fake\u{2029}App") == "Raycast Fake App")
        #expect(SenderText.name("Raycast\nFake\tApp\r") == "Raycast Fake App")
        #expect(SenderText.name("Ray\u{2066}cast\u{2069} \u{2067}x\u{2068}") == "Raycast x")
        #expect(SenderText.name("Ray\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}cast\u{200E}\u{200F}\u{061C}") == "Raycast")
        #expect(SenderText.name("\u{200B}Ray\u{200C}\u{200D}cast\u{2060}\u{FEFF}") == "Raycast")
        let stacked = "R" + String(repeating: "\u{0301}", count: 9000) + "aycast"
        #expect(SenderText.name(stacked) == "R\u{0301}\u{0301}aycast")
        #expect(SenderText.name("e\u{0301}\u{0302}\u{20DD}\u{0903}x") == "e\u{0301}\u{0302}x")
        #expect(SenderText.name("\u{3164}\u{2800}\u{115F}\u{1160}\u{FFA0}") == nil)
        #expect(SenderText.name("\n\t \u{200B}\u{2028}") == nil)
        #expect(SenderText.name("") == nil)
        #expect(SenderText.name(nil) == nil)
        #expect(SenderText.name("  Raycast  ") == "Raycast")
        #expect(SenderText.name(String(repeating: "n", count: 60)) == String(repeating: "n", count: 39) + "…")
        // Counted after sanitising: 40 visible characters with format characters between them stay whole.
        let forty = Array(repeating: "m", count: 40).joined(separator: "\u{200B}")
        #expect(SenderText.name(forty) == String(repeating: "m", count: 40))
    }

    /// An invisible filler between marks mustn't reset the mark count, and characters that join into one grapheme
    /// (prepend characters, Hangul jamo, emoji modifiers) mustn't carry thousands of scalars past the 40-character cap.
    /// A name is also cut at 80 Unicode scalars.
    @Test func aSendersNameCantBeStretched() {
        #expect(SenderText.scalarLimit == 80)
        let interleaved = "R" + String(repeating: "\u{0301}\u{0301}\u{3164}", count: 3000)
        #expect(SenderText.name(interleaved) == "R\u{0301}\u{0301}")
        // Unassigned and default-ignorable code points draw nothing either, and don't start a new count.
        for invisible in ["\u{2065}", "\u{FFF0}", "\u{E0001}", "\u{E0080}"] {
            let stacked = "R" + String(repeating: "\u{0301}\u{0301}" + invisible, count: 3000)
            #expect(SenderText.name(stacked) == "R\u{0301}\u{0301}", "\(invisible.unicodeScalars.first!.value)")
            #expect(SenderText.name("Ray" + invisible + "cast") == "Raycast")
        }
        let prepended = String(repeating: "\u{0D4E}", count: 3000) + "a"
        #expect(SenderText.name(prepended) == String(repeating: "\u{0D4E}", count: 79) + "…")
        for stretched in [String(repeating: "\u{1100}", count: 3000), "👍" + String(repeating: "\u{1F3FB}", count: 3000)] {
            let shown = SenderText.name(stretched) ?? ""
            #expect(shown.unicodeScalars.count == SenderText.scalarLimit)
            #expect(shown.hasSuffix("…"))
            #expect(shown.count <= APIRequest.shownNameLimit)
        }
        // Within both caps nothing changes.
        let eighty = String(repeating: "e\u{0301}", count: 40)
        #expect(SenderText.name(eighty) == eighty)
    }

    /// A free Apple Development certificate can sign any name and bundle ID, so only a Developer ID or Mac App Store
    /// signature verifies a developer's app, and Apple's own code is `anchor apple`. The requirement takes the team
    /// only in its real shape, so nothing can be added to it.
    @Test func onlyDeveloperIDOrAppStoreSignaturesVerify() {
        #expect(VerifiedSender.appleRequirement == "anchor apple")
        #expect(VerifiedSender.developerRequirement(team: "SY64MV22J9")
            == "anchor apple generic and (certificate leaf[field.1.2.840.113635.100.6.1.9] or "
            + "(certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] "
            + "and certificate leaf[subject.OU] = \"SY64MV22J9\"))")
        #expect(VerifiedSender.developerRequirement(team: "SY64MV22J9\" or anchor apple generic or \"") == nil)
        #expect(VerifiedSender.developerRequirement(team: "") == nil)
        // An Apple Development or ad-hoc sender isn't verified: the app passes no signature, and a name found for it is
        // "an unverified app".
        let development = SenderFacts(pid: 500, bundleID: "com.raycast.macos", name: "Raycast", auditToken: nil,
                                      verified: nil)
        #expect(URLConsent.describe(development) == "an unverified app")
    }

    /// A file name isn't signed, so a copy of osascript renamed "Raycast" would have shown as "Raycast (Apple)". A
    /// verified name comes only from the signed Info.plist (display name, else bundle name); a tool without one is
    /// named by its signed identifier, and the identifier always shows beside a name.
    @Test func aToolIsNamedByItsSignedIdentifierNeverItsFileName() {
        let renamed: [String: Any] = [
            SigningKey.identifier: "com.apple.osascript",
            SigningKey.mainExecutable: URL(filePath: "/tmp/Raycast"),
        ]
        let tool = VerifiedSender(signingInformation: renamed, signer: .apple)
        #expect(tool == VerifiedSender(identifier: "com.apple.osascript", signer: .apple, name: nil))
        let fromTool = SenderFacts(pid: 600, bundleID: nil, name: nil, auditToken: nil, verified: tool)
        #expect(URLConsent.describe(fromTool) == "com.apple.osascript (Apple)")
        #expect(URLConsent.captureNotice(sender: fromTool) == "com.apple.osascript (Apple) is capturing your screen with ClearShot")

        let terminal: [String: Any] = [
            SigningKey.identifier: "com.apple.Terminal",
            SigningKey.plist: ["CFBundleName": "Terminal", "CFBundleExecutable": "Terminal"],
            SigningKey.mainExecutable: URL(filePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]
        let app = VerifiedSender(signingInformation: terminal, signer: .apple)
        #expect(app?.name == "Terminal")
        #expect(URLConsent.describe(SenderFacts(pid: 601, bundleID: nil, name: nil, auditToken: nil, verified: app))
            == "Terminal (com.apple.Terminal, Apple)")

        // The display name first, then the bundle name; nothing else in the Info.plist names it.
        let displayed: [String: Any] = [
            SigningKey.identifier: "com.raycast.macos",
            SigningKey.plist: ["CFBundleDisplayName": "Raycast", "CFBundleName": "raycast-app"],
        ]
        #expect(VerifiedSender(signingInformation: displayed, signer: .team("SY64MV22J9"))?.name == "Raycast")
        let executableOnly: [String: Any] = [
            SigningKey.identifier: "com.example.tool",
            SigningKey.plist: ["CFBundleExecutable": "Raycast"],
        ]
        #expect(VerifiedSender(signingInformation: executableOnly, signer: .team("ABCDE12345"))?.name == nil)
        // No signed identifier: not verified at all.
        #expect(VerifiedSender(signingInformation: [SigningKey.plist: ["CFBundleName": "Raycast"]],
                               signer: .apple) == nil)
    }

    /// Identifiers (bundle IDs, team IDs) show only ASCII letters, digits, dots and hyphens; anything else is escaped.
    @Test func anIdentifierShowsOnlyPlainCharacters() {
        #expect(SenderText.code("com.raycast.macos") == "com.raycast.macos")
        #expect(SenderText.code("com.evil\u{202E}app") == "com.evil%E2%80%AEapp")
        #expect(SenderText.code("a b/c") == "a%20b%2Fc")
        #expect(SenderText.code("com.\u{0435}vil") == "com.%D0%B5vil")
        #expect(SenderText.code("com." + String(repeating: "x", count: 60))
            == "com." + String(repeating: "x", count: 35) + "…")
        // A team ID goes into a code requirement, so only the real shape is accepted.
        #expect(VerifiedSender.isTeamID("SY64MV22J9"))
        #expect(!VerifiedSender.isTeamID("sy64mv22j9"))
        #expect(!VerifiedSender.isTeamID("SY64MV22J"))
        #expect(!VerifiedSender.isTeamID("SY64MV22J9\" or anchor apple"))
        #expect(!VerifiedSender.isTeamID(""))
    }

    /// Opening a URL activates ClearShot, so the prompt can take the keys while the person types elsewhere. Don't Allow
    /// is the default (Return, and Esc); Allow has no key, is never focused from the keyboard, and is enabled only 1.5
    /// s after the alert appears, so a stray Return or a click already on its way can't allow anything.
    @Test func onlyADeliberateClickAllows() {
        let buttons = URLConsent.buttons
        #expect(buttons.map(\.title) == ["Don't Allow", "Allow"])
        #expect(buttons.map(\.allows) == [false, true])
        #expect(buttons.map(\.isDefault) == [true, false])
        #expect(buttons.map(\.enabledAfter) == [0, 1.5])
        #expect(buttons.filter(\.isDefault).count == 1)
        #expect(buttons.allSatisfy { !($0.allows && $0.isDefault) })
        #expect(buttons.allSatisfy { !$0.allows || $0.enabledAfter >= 1.5 })
        // The alert's answer is the index of the button chosen; anything else allows nothing.
        #expect(!URLConsent.allows(choosing: 0))
        #expect(URLConsent.allows(choosing: 1))
        #expect(!URLConsent.allows(choosing: 2))
        #expect(!URLConsent.allows(choosing: -1))
    }

    /// A capture that takes the picture with no on-screen choice says who asked for it, unless ClearShot asked itself.
    /// Another ClearShot (a second copy forwarding) and an unnamed sender aren't ClearShot.
    @Test func theCaptureNoticeShowsForAnotherSendersCaptureWithNoChoice() {
        let noChoice = APICommand.captureFullscreen(action: nil)
        let overlay = APICommand.captureArea(nil, action: nil)
        let us = SenderFacts(pid: ownPID, bundleID: "test.clearshot", name: nil, auditToken: nil)
        let copy = SenderFacts(pid: 999, bundleID: "test.clearshot", name: nil, auditToken: nil)
        let nobody = SenderFacts(pid: nil, bundleID: nil, name: nil, auditToken: nil)
        for sender in [raycast, exited, copy, nobody] {
            #expect(URLConsent.showsCaptureNotice(for: noChoice, sender: sender, ownPID: ownPID), "\(sender)")
            #expect(!URLConsent.showsCaptureNotice(for: overlay, sender: sender, ownPID: ownPID), "\(sender)")
        }
        #expect(!URLConsent.showsCaptureNotice(for: noChoice, sender: us, ownPID: ownPID))
    }
}

/// Commands that arrive while the consent prompt is up wait for its answer.
struct ConsentQueueTests {
    let sender = SenderFacts(pid: 500, bundleID: "com.raycast.macos", name: "Raycast", auditToken: nil)

    func received(_ number: Int) -> ReceivedURL {
        ReceivedURL(url: api("clearshot://capture-fullscreen?n=\(number)"), sender: sender,
                    receivedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(number)))
    }

    @Test func atMostEightWaitAndRunInOrderOnAllow() {
        #expect(ConsentQueue.limit == 8)
        var queue = ConsentQueue()
        #expect(!queue.isAsking)
        queue.begin(received(0))
        #expect(queue.isAsking)
        let added = (1 ... 9).map { queue.add(received($0)) }
        #expect(added == Array(repeating: true, count: 8) + [false])
        let allowed = queue.answer(allowed: true)
        #expect(allowed == (0 ... 8).map(received))
        #expect(!queue.isAsking)
        // The next question starts empty.
        queue.begin(received(10))
        let next = queue.answer(allowed: true)
        #expect(next == [received(10)])
    }

    @Test func dontAllowDropsThemAll() {
        var queue = ConsentQueue()
        queue.begin(received(0))
        let added = [queue.add(received(1)), queue.add(received(2))]
        #expect(added == [true, true])
        // What Don't Allow drops, for the log.
        #expect(queue.pending == [received(0), received(1), received(2)])
        let refused = queue.answer(allowed: false)
        #expect(refused.isEmpty)
        #expect(queue.pending.isEmpty)
        #expect(!queue.isAsking)
        // Nothing dropped comes back with a later answer; a second begin while asking waits like add.
        queue.begin(received(3))
        queue.begin(received(4))
        let next = queue.answer(allowed: true)
        #expect(next == [received(3), received(4)])
    }

    /// The modal gate is asked before the prompt begins, and only when no prompt is up. A refused prompt leaves nothing
    /// behind, so the next command asks again (the person hasn't been asked). While the prompt is up, commands wait
    /// without asking the gate, and one beyond `limit` is dropped rather than lost silently.
    @Test func aRefusedPromptLeavesTheQueueUsable() {
        var queue = ConsentQueue()
        var gateAsked = 0
        let refusing = queue.arrive(received(0)) {
            gateAsked += 1
            return false
        }
        #expect(refusing == .refused)
        #expect(gateAsked == 1)
        #expect(!queue.isAsking)
        #expect(queue.pending.isEmpty)

        let asking = queue.arrive(received(1)) {
            gateAsked += 1
            return true
        }
        #expect(asking == .asks)
        #expect(queue.isAsking)
        #expect(gateAsked == 2)
        let arrivals = (2 ... 10).map { number in
            queue.arrive(received(number)) {
                gateAsked += 1
                return true
            }
        }
        #expect(arrivals == Array(repeating: .waits, count: ConsentQueue.limit) + [.dropped])
        #expect(gateAsked == 2)
        #expect(queue.pending == (1 ... 9).map(received))
        #expect(queue.answer(allowed: true) == (1 ... 9).map(received))
        #expect(queue.pending.isEmpty)
        #expect(!queue.isAsking)
    }
}

/// An app without consent asks the modal gate before the prompt, and a refusal says so in a HUD and brings an open
/// dialog forward. Each sender gets one of those per `interval`; the rest are only logged.
struct RefusalNoticesTests {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func signed(_ identifier: String, pid: Int32) -> SenderFacts {
        SenderFacts(pid: pid, bundleID: identifier, name: nil, auditToken: nil,
                    verified: VerifiedSender(identifier: identifier, signer: .team("ABCDE12345"), name: nil))
    }

    @Test func oneRefusalShowsPerSenderPerTenSeconds() {
        #expect(RefusalNotices.interval == 10)
        var notices = RefusalNotices()
        let raycast = signed("com.raycast.macos", pid: 500)
        #expect(notices.mayShow(for: raycast, at: start))
        // Asking doesn't count; only a refusal that showed does.
        #expect(notices.mayShow(for: raycast, at: start + 1))
        notices.shown(for: raycast, at: start + 1)
        #expect(!notices.mayShow(for: raycast, at: start + 1))
        #expect(!notices.mayShow(for: raycast, at: start + 10.9))
        #expect(notices.mayShow(for: raycast, at: start + 11))
        // The same app from another process (a new `open` each time) is the same sender.
        #expect(!notices.mayShow(for: signed("com.raycast.macos", pid: 501), at: start + 5))
        // Another app has its own.
        #expect(notices.mayShow(for: signed("com.example.tool", pid: 600), at: start + 5))
    }

    /// Senders are told apart as the prompt names them, so an app can't get a HUD per process by not being verified.
    @Test func unverifiedAndUnknownSendersShareOne() {
        var notices = RefusalNotices()
        let first = SenderFacts(pid: 700, bundleID: "com.example.a", name: "A", auditToken: nil)
        let second = SenderFacts(pid: 701, bundleID: "com.example.b", name: "B", auditToken: nil)
        notices.shown(for: first, at: start)
        #expect(!notices.mayShow(for: second, at: start + 1))
        let gone = SenderFacts(pid: 702, bundleID: nil, name: nil, auditToken: nil)
        let alsoGone = SenderFacts(pid: nil, bundleID: nil, name: nil, auditToken: nil)
        #expect(notices.mayShow(for: gone, at: start + 1))
        notices.shown(for: gone, at: start + 1)
        #expect(!notices.mayShow(for: alsoGone, at: start + 2))
    }

    /// Senders whose interval has passed are forgotten, so the record stays small.
    @Test func oldSendersAreForgotten() {
        var notices = RefusalNotices()
        for number in 0 ..< 50 {
            notices.shown(for: signed("com.example.app\(number)", pid: 800), at: start)
        }
        #expect(notices.trackedSenders == 50)
        notices.shown(for: signed("com.example.late", pid: 900), at: start + 10)
        #expect(notices.trackedSenders == 1)
    }
}
