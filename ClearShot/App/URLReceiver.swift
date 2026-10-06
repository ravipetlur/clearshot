import AppKit
import CSAPI
import CSCore
import Darwin
import Security

/// Receives `clearshot://` URLs through a `kAEGetURL` handler, installed as launch begins: a URL that launches
/// ClearShot arrives before `applicationDidFinishLaunching`, and without the handler it would reach
/// `application(_:open:)` and be imported as a file. The handler only reads the event and queues the URL in the inbox
/// (`URLInbox`): it names the sender then and there, because `/usr/bin/open` and the like are gone moments later, and
/// shows nothing, since events can arrive during a modal session. URLs wait until the app has started (`open`), or, in
/// a second copy handing off to the running one, are forwarded (`forwardFromNowOn`).
final class URLReceiver: NSObject {
    private let ownBundleID: String
    private var inbox = URLInbox()
    /// Takes each URL once the app has started (`open`).
    private var handler: ((ReceivedURL) -> Void)?
    /// Takes each URL that arrives while this copy hands off to the running one.
    var onForward: ((URL) -> Void)?

    init(ownBundleID: String = CSCore.bundleIdentifier) {
        self.ownBundleID = ownBundleID
        super.init()
    }

    /// In `applicationWillFinishLaunching`, before any URL can arrive.
    func install() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    /// The app has started: `handler` takes the URLs held since launch, oldest first, then each one as it comes.
    func open(handler: @escaping (ReceivedURL) -> Void) {
        self.handler = handler
        for received in inbox.open() {
            handler(received)
        }
    }

    /// This copy is handing off to the running one: the URLs held since launch, oldest first; later ones go to
    /// `onForward`.
    func forwardFromNowOn() -> [URL] {
        inbox.forwardFromNowOn()
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else {
            Log.api.error("Ignored a URL event without a URL")
            return
        }
        guard let url = URL(string: string) else {
            Log.api.error("Ignored a URL event whose text isn't a URL (\(string.count) characters)")
            return
        }
        let eventPID = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        let auditToken = event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data
        // The audit token's PID; without a token, or with a PID attribute that disagrees, the sender is unknown.
        let pid = SenderPID.of(eventPID: eventPID, auditToken: auditToken)
        if pid == nil {
            let tokenPID = SenderPID.inAuditToken(auditToken)
            Log.api.warning("The sender is unknown: the event's PID is \(eventPID.map(String.init) ?? "missing"), its "
                + "audit token's \(tokenPID.map(String.init) ?? "missing")")
        }
        var sender: SenderFacts?
        let disposition = inbox.receive(url, senderPID: pid, receivedAt: Date()) { pid in
            let facts = SenderNaming.facts(pid: pid, auditToken: auditToken, ownBundleID: ownBundleID,
                                           verified: Self.verifiedSender(auditToken: auditToken),
                                           lookup: { Self.processFacts($0) })
            sender = facts
            return facts
        }
        let command = APIRequest.shortened(APIRequest.commandName(of: url))
        switch disposition {
        case .held:
            Log.api.info("Received \(command) from \(Self.describe(sender, pid: pid))")
        case .handle(let received):
            Log.api.info("Received \(command) from \(Self.describe(received.sender, pid: pid))")
            handler?(received)
        case .forward(let url):
            Log.api.info("Received \(command) while handing off; forwarding it to the running ClearShot")
            onForward?(url)
        case .dropped:
            Log.api.error("Dropped \(command) (pid \(pid.map(String.init) ?? "unknown")): \(URLInbox.heldLimit) URLs "
                + "already wait for ClearShot to start")
        }
    }

    /// "Raycast (com.raycast.macos, team …) (pid 812)", "an external app (pid 812)" for one that has exited or is another
    /// ClearShot, or "an unverified app (pid 812; under “Terminal”, unverified)" with the first app found above it. Every
    /// part is sanitised (`URLConsent.describe`, `SenderText`), so a name can't forge log lines.
    private static func describe(_ sender: SenderFacts?, pid: Int32?) -> String {
        let pidText = "pid \(pid.map(String.init) ?? "unknown")"
        guard let sender else { return "an external app (\(pidText))" }
        let walked = sender.verified == nil ? SenderText.name(sender.name) : nil
        return "\(URLConsent.describe(sender)) (\(pidText)\(walked.map { "; under “\($0)”, unverified" } ?? ""))"
    }

    /// The sending process's own code signature, from the event's audit token: read now, while it runs, and only when
    /// it checks out, valid and either Apple's own (`VerifiedSender.appleRequirement`) or signed for distribution,
    /// Developer ID or Mac App Store (`developerRequirement`). Nil when the process has exited, is unsigned, ad-hoc or
    /// development signed, or its signature fails. What it says comes only from what the signature seals
    /// (`VerifiedSender(signingInformation:signer:)`): the signing identifier and a name from the signed Info.plist,
    /// never the executable's file name, which a renamed copy can choose.
    private static func verifiedSender(auditToken: Data?) -> VerifiedSender? {
        guard let auditToken else { return nil }
        var code: SecCode?
        let guest = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, guest, [], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        let signer: VerifiedSender.Signer
        if satisfies(code, VerifiedSender.appleRequirement) {
            signer = .apple
        } else if let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
                  let requirement = VerifiedSender.developerRequirement(team: team), satisfies(code, requirement) {
            signer = .team(team)
        } else {
            return nil
        }
        return VerifiedSender(signingInformation: info, signer: signer)
    }

    /// Whether the running `code` is valid and meets `requirement` (the code requirement language).
    private static func satisfies(_ code: SecCode, _ requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else {
            return false
        }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }

    /// A running process as `SenderNaming` walks it: its parent from `sysctl KERN_PROC_PID`, its bundle ID and name
    /// from `NSRunningApplication`. Nil when it has exited.
    private static func processFacts(_ pid: Int32) -> ProcessFacts? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let parent: Int32? = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 && size > 0
            ? info.kp_eproc.e_ppid : nil
        let app = NSRunningApplication(processIdentifier: pid)
        guard parent != nil || app != nil else { return nil }
        return ProcessFacts(parentPID: parent, bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }
}
