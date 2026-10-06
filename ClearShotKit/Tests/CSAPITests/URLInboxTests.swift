import Foundation
import Testing
@testable import CSAPI

/// URLs that arrive before launch finishes wait in the inbox, with their sender named as it was when each arrived.
struct URLInboxTests {
    let raycast = ProcessFacts(parentPID: 1, bundleID: "com.raycast.macos", name: "Raycast")
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func named(_ pid: Int32, _ name: String?, bundleID: String?) -> SenderFacts {
        SenderFacts(pid: pid, bundleID: bundleID, name: name, auditToken: nil)
    }

    @Test func aURLBeforeStartIsHeldWithTheSenderReadAtReceipt() {
        // The process table as it is when the URL arrives; Raycast quits before launch finishes, so a lookup made any
        // later can't name it.
        var processes: [Int32: ProcessFacts] = [500: raycast]
        let lookup: (pid_t) -> SenderFacts = { pid in
            SenderNaming.facts(pid: pid, auditToken: nil, ownBundleID: "test.clearshot") { processes[$0] }
        }
        var inbox = URLInbox()
        let url = api("clearshot://capture-area")
        let disposition = inbox.receive(url, senderPID: 500, receivedAt: start, lookup: lookup)
        #expect(disposition == .held)
        processes = [:]
        #expect(lookup(500).name == nil)

        let held = inbox.open()
        #expect(held == [ReceivedURL(url: url, sender: named(500, "Raycast", bundleID: "com.raycast.macos"), receivedAt: start)])
    }

    @Test func openingReturnsTheHeldOnesOldestFirstThenHandlesTheRest() {
        var lookups: [pid_t] = []
        let lookup: (pid_t) -> SenderFacts = { pid in
            lookups.append(pid)
            return SenderFacts(pid: pid, bundleID: nil, name: "p\(pid)", auditToken: nil)
        }
        var inbox = URLInbox()
        let urls = (0 ..< 3).map { api("clearshot://capture-fullscreen?n=\($0)") }
        let anonymous = api("clearshot://open-history")
        let dispositions = [
            inbox.receive(urls[0], senderPID: 500, receivedAt: start, lookup: lookup),
            inbox.receive(urls[1], senderPID: 501, receivedAt: start + 1, lookup: lookup),
            inbox.receive(urls[2], senderPID: 502, receivedAt: start + 2, lookup: lookup),
            // An event without a sender PID is held unnamed, without a lookup.
            inbox.receive(anonymous, senderPID: nil, receivedAt: start + 3, lookup: lookup),
        ]
        #expect(dispositions == Array(repeating: .held, count: 4))
        #expect(lookups == [500, 501, 502])

        let held = inbox.open()
        #expect(held == [
            ReceivedURL(url: urls[0], sender: named(500, "p500", bundleID: nil), receivedAt: start),
            ReceivedURL(url: urls[1], sender: named(501, "p501", bundleID: nil), receivedAt: start + 1),
            ReceivedURL(url: urls[2], sender: named(502, "p502", bundleID: nil), receivedAt: start + 2),
            ReceivedURL(url: anonymous, sender: SenderFacts(pid: nil, bundleID: nil, name: nil, auditToken: nil),
                        receivedAt: start + 3),
        ])

        let later = api("clearshot://pin")
        let handled = inbox.receive(later, senderPID: 600, receivedAt: start + 10, lookup: lookup)
        #expect(handled == .handle(ReceivedURL(url: later, sender: named(600, "p600", bundleID: nil), receivedAt: start + 10)))
        #expect(lookups == [500, 501, 502, 600])
        // Nothing is held any more.
        let heldAfter = inbox.open()
        #expect(heldAfter.isEmpty)
    }

    /// A burst of URLs before launch finishes is held up to `heldLimit`; the rest are dropped, without naming their
    /// senders, for the receiver to log. Once the app has started nothing is dropped here.
    @Test func atMostThirtyTwoAreHeldBeforeStart() {
        #expect(URLInbox.heldLimit == 32)
        var lookups = 0
        let lookup: (pid_t) -> SenderFacts = { pid in
            lookups += 1
            return SenderFacts(pid: pid, bundleID: nil, name: nil, auditToken: nil)
        }
        var inbox = URLInbox()
        let urls = (0 ..< 40).map { api("clearshot://capture-fullscreen?n=\($0)") }
        let dispositions = urls.enumerated().map { index, url in
            inbox.receive(url, senderPID: 500, receivedAt: start + Double(index), lookup: lookup)
        }
        #expect(dispositions == Array(repeating: .held, count: 32) + Array(repeating: .dropped, count: 8))
        #expect(lookups == 32)
        #expect(inbox.open().map(\.url) == Array(urls.prefix(32)))

        // Started: every URL is handled.
        let later = (0 ..< 40).map { index in
            inbox.receive(api("clearshot://pin?n=\(index)"), senderPID: 600, receivedAt: start + 100, lookup: lookup)
        }
        #expect(!later.contains(.dropped))
        #expect(!later.contains(.held))
    }

    /// A second copy hands everything to the running one: what it held, then whatever comes in until it quits. The
    /// running copy sees the forwarding copy as the sender, so a forwarded URL isn't named here.
    @Test func aCopyHandingOffForwardsTheHeldAndLaterURLs() {
        var lookups = 0
        let lookup: (pid_t) -> SenderFacts = { pid in
            lookups += 1
            return SenderFacts(pid: pid, bundleID: nil, name: nil, auditToken: nil)
        }
        var inbox = URLInbox()
        let first = api("clearshot://capture-area"), second = api("clearshot://open-settings?tab=general")
        let held = [inbox.receive(first, senderPID: 500, receivedAt: start, lookup: lookup),
                    inbox.receive(second, senderPID: 501, receivedAt: start + 1, lookup: lookup)]
        #expect(held == [.held, .held])
        let forwarded = inbox.forwardFromNowOn()
        #expect(forwarded == [first, second])

        let third = api("clearshot://pin")
        let later = inbox.receive(third, senderPID: 502, receivedAt: start + 2, lookup: lookup)
        #expect(later == .forward(third))
        #expect(lookups == 2)
        let forwardedAfter = inbox.forwardFromNowOn()
        #expect(forwardedAfter.isEmpty)
    }
}
