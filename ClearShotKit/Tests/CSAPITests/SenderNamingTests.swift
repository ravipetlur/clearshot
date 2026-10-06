import Foundation
import Testing
@testable import CSAPI

struct SenderNamingTests {
    let own = "test.clearshot"
    let token = Data(repeating: 7, count: 32)
    let raycast = ProcessFacts(parentPID: 1, bundleID: "com.raycast.macos", name: "Raycast")

    func facts(pid: Int32?, _ table: [Int32: ProcessFacts]) -> SenderFacts {
        SenderNaming.facts(pid: pid, auditToken: token, ownBundleID: own) { table[$0] }
    }

    @Test func anAppSenderIsNamedByItself() {
        #expect(facts(pid: 500, [500: raycast])
            == SenderFacts(pid: 500, bundleID: "com.raycast.macos", name: "Raycast", auditToken: token))
    }

    @Test func aCLIIsNamedByTheFirstAppAboveIt() {
        let table: [Int32: ProcessFacts] = [
            30: ProcessFacts(parentPID: 20, bundleID: nil, name: "zsh"),
            20: ProcessFacts(parentPID: 10, bundleID: nil, name: "login"),
            10: ProcessFacts(parentPID: 1, bundleID: "com.apple.Terminal", name: "Terminal"),
        ]
        #expect(facts(pid: 30, table)
            == SenderFacts(pid: 30, bundleID: "com.apple.Terminal", name: "Terminal", auditToken: token))
    }

    /// `/usr/bin/open` has exited by the time its URL is handled: the PID is kept for the log, and the sender has no
    /// name.
    @Test func aSenderThatHasExitedIsUnnamed() {
        #expect(facts(pid: 30, [:]) == SenderFacts(pid: 30, bundleID: nil, name: nil, auditToken: token))
        // A parent gone midway leaves it unnamed too.
        #expect(facts(pid: 30, [30: ProcessFacts(parentPID: 20, bundleID: nil, name: "zsh")])
            == SenderFacts(pid: 30, bundleID: nil, name: nil, auditToken: token))
        // An event without a sender PID.
        #expect(facts(pid: nil, [500: raycast]) == SenderFacts(pid: nil, bundleID: nil, name: nil, auditToken: token))
    }

    /// A second ClearShot forwarding what it got: the original sender can't be known, so it isn't named after us.
    @Test func ourOwnBundleIDIsUnnamed() {
        let copy = ProcessFacts(parentPID: 1, bundleID: own, name: "ClearShot")
        #expect(facts(pid: 777, [777: copy]) == SenderFacts(pid: 777, bundleID: own, name: nil, auditToken: token))
        // Also when found above a helper.
        #expect(facts(pid: 778, [778: ProcessFacts(parentPID: 777, bundleID: nil, name: "helper"), 777: copy])
            == SenderFacts(pid: 778, bundleID: own, name: nil, auditToken: token))
    }

    /// The immediate sender's verified signature, read from the audit token at receipt, rides with the facts; the
    /// walk's name and bundle ID stay as they were, for the log.
    @Test func aVerifiedSenderIsKept() {
        let verified = VerifiedSender(identifier: "com.raycast.macos", signer: .team("SY64MV22J9"), name: "Raycast")
        let sender = SenderNaming.facts(pid: 500, auditToken: token, ownBundleID: own, verified: verified) { pid in
            pid == 500 ? raycast : nil
        }
        #expect(sender == SenderFacts(pid: 500, bundleID: "com.raycast.macos", name: "Raycast", auditToken: token,
                                      verified: verified))
        // Without one, nothing is verified.
        #expect(facts(pid: 500, [500: raycast]).verified == nil)
    }

    /// A second ClearShot forwarding a command is ClearShot's own signature: the original sender can't be known, so it is
    /// never shown as verified.
    @Test func aSecondClearShotIsNeverVerified() {
        let copy = ProcessFacts(parentPID: 1, bundleID: own, name: "ClearShot")
        let ours = VerifiedSender(identifier: own, signer: .team("ABCDE12345"), name: "ClearShot")
        let sender = SenderNaming.facts(pid: 777, auditToken: token, ownBundleID: own, verified: ours) { $0 == 777 ? copy : nil }
        #expect(sender.verified == nil)
        #expect(sender.name == nil)
    }

    @Test func theWalkStopsAtLaunchdAndAfterSixteenSteps() {
        #expect(SenderNaming.maximumDepth == 16)
        // launchd (PID 1) is never looked up.
        var asked: [Int32] = []
        let toLaunchd: [Int32: ProcessFacts] = [
            30: ProcessFacts(parentPID: 20, bundleID: nil, name: "zsh"),
            20: ProcessFacts(parentPID: 1, bundleID: nil, name: "login"),
            1: ProcessFacts(parentPID: 0, bundleID: "com.apple.launchd", name: "launchd"),
        ]
        let unnamed = SenderNaming.facts(pid: 30, auditToken: nil, ownBundleID: own) { pid in
            asked.append(pid)
            return toLaunchd[pid]
        }
        #expect(unnamed.name == nil)
        #expect(asked == [30, 20])

        // A chain of plain processes, the sender first: the 16th is looked at, the 17th never.
        func chain(appAt depth: Int32) -> (SenderFacts, Int) {
            var lookups = 0
            let sender = SenderNaming.facts(pid: 100, auditToken: nil, ownBundleID: own) { pid in
                lookups += 1
                return ProcessFacts(parentPID: pid + 1, bundleID: pid == 100 + depth ? "com.example.app" : nil, name: "p\(pid)")
            }
            return (sender, lookups)
        }
        let sixteenth = chain(appAt: 15)
        #expect(sixteenth.0.name == "p115")
        #expect(sixteenth.1 == 16)
        let seventeenth = chain(appAt: 16)
        #expect(seventeenth.0.name == nil)
        #expect(seventeenth.1 == 16)
    }
}

/// The sender's PID comes from the event's audit token, which the kernel fills in, not from `keySenderPIDAttr`. When
/// both are there and disagree, the sender is unknown.
struct SenderPIDTests {
    /// An `audit_token_t` as the event carries it: eight 32-bit words, the PID the sixth (`audit_token_to_pid`).
    func token(pid: Int32) -> Data {
        let words: [UInt32] = [501, 501, 20, 501, 20, UInt32(bitPattern: pid), 100_123, 7]
        return words.withUnsafeBytes { Data($0) }
    }

    @Test func thePIDIsTheAuditTokens() {
        #expect(SenderPID.inAuditToken(token(pid: 812)) == 812)
        #expect(SenderPID.of(eventPID: 812, auditToken: token(pid: 812)) == 812)
        // The token alone is enough.
        #expect(SenderPID.of(eventPID: nil, auditToken: token(pid: 812)) == 812)
    }

    @Test func aPIDAttributeThatDisagreesLeavesTheSenderUnknown() {
        #expect(SenderPID.of(eventPID: 999, auditToken: token(pid: 812)) == nil)
        // Not even our own PID is taken from the attribute.
        #expect(SenderPID.of(eventPID: getpid(), auditToken: token(pid: 812)) == nil)
    }

    @Test func withoutAWellFormedTokenTheSenderIsUnknown() {
        #expect(SenderPID.of(eventPID: 812, auditToken: nil) == nil)
        #expect(SenderPID.inAuditToken(nil) == nil)
        #expect(SenderPID.inAuditToken(Data(repeating: 0, count: 31)) == nil)
        #expect(SenderPID.inAuditToken(Data(repeating: 0, count: 33)) == nil)
        #expect(SenderPID.of(eventPID: 812, auditToken: Data(repeating: 0, count: 16)) == nil)
    }
}
