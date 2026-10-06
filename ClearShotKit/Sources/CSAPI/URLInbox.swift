import Foundation

/// A URL as it arrived, with its sender as named then.
public struct ReceivedURL: Sendable, Equatable {
    public let url: URL, sender: SenderFacts, receivedAt: Date

    public init(url: URL, sender: SenderFacts, receivedAt: Date) {
        self.url = url
        self.sender = sender
        self.receivedAt = receivedAt
    }
}

/// Where URLs go from the moment the receiver is installed (`applicationWillFinishLaunching`): held until the app has
/// started, then handled as they come; or, in a second copy handing off to the running one, forwarded.
public struct URLInbox: Sendable {
    public enum Disposition: Sendable, Equatable {
        /// Kept until `open()`.
        case held
        /// Handle it now.
        case handle(ReceivedURL)
        /// Send it to the running copy.
        case forward(URL)
        /// `heldLimit` URLs already wait for the app to start: it is dropped, for the receiver to log.
        case dropped
    }

    /// The most URLs held before the app has started: a burst at launch can't grow the inbox without bound, or name a
    /// sender for each.
    public static let heldLimit = 32

    private enum Mode { case holding, handling, forwarding }

    private var mode = Mode.holding
    private var held: [ReceivedURL] = []

    public init() {}

    /// Takes a URL as it arrives. `lookup` names the sender (`SenderNaming.facts`), and runs here and now, at receipt,
    /// never later: a sender like `/usr/bin/open` is gone soon after. It isn't run for an event without a sender PID
    /// (the sender stays unnamed), nor for a URL that is forwarded (the running copy sees the forwarding copy as its
    /// sender anyway) or dropped because `heldLimit` URLs already wait.
    public mutating func receive(_ url: URL, senderPID: pid_t?, receivedAt: Date,
                                 lookup: (pid_t) -> SenderFacts) -> Disposition {
        if mode == .forwarding { return .forward(url) }
        if mode == .holding, held.count >= Self.heldLimit { return .dropped }
        let sender = senderPID.map(lookup) ?? SenderFacts(pid: nil, bundleID: nil, name: nil, auditToken: nil)
        let received = ReceivedURL(url: url, sender: sender, receivedAt: receivedAt)
        guard mode == .handling else {
            held.append(received)
            return .held
        }
        return .handle(received)
    }

    /// The app has started: returns the held URLs, oldest first; from now on `receive` says `.handle`.
    public mutating func open() -> [ReceivedURL] {
        mode = .handling
        return takeHeld()
    }

    /// This copy is handing off to the running one: returns the held URLs, oldest first; from now on `receive` says
    /// `.forward`.
    public mutating func forwardFromNowOn() -> [URL] {
        mode = .forwarding
        return takeHeld().map(\.url)
    }

    private mutating func takeHeld() -> [ReceivedURL] {
        defer { held = [] }
        return held
    }
}
