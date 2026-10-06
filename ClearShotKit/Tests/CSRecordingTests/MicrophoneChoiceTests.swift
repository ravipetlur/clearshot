import CSCore
import Testing
@testable import CSRecording

struct MicrophoneChoiceTests {
    let builtIn = MicrophoneDeviceInfo(id: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isBuiltIn: true)
    let usb = MicrophoneDeviceInfo(id: "AppleUSBAudioEngine:Blue:Yeti:1", name: "Yeti", isBuiltIn: false)
    var devices: [MicrophoneDeviceInfo] { [builtIn, usb] }

    /// "Do Not Record Microphone" never turns into a device, even with one plugged in.
    @Test func doNotRecordStaysNil() {
        #expect(MicrophoneChoice.usable(savedID: "", devices: devices, lidClosed: false) == nil)
        #expect(MicrophoneChoice.usable(savedID: "", devices: [usb], lidClosed: true) == nil)
    }

    @Test func theBuiltInMicIsRefusedWithTheLidClosed() {
        #expect(MicrophoneChoice.lidClosedReason
            == "The built-in microphone doesn't work while the MacBook's lid is closed.")
        #expect(MicrophoneChoice.unavailableReason(builtIn, lidClosed: true) == MicrophoneChoice.lidClosedReason)
        #expect(MicrophoneChoice.usable(savedID: builtIn.id, devices: devices, lidClosed: true) == nil)
        // With the lid open it is fine.
        #expect(MicrophoneChoice.unavailableReason(builtIn, lidClosed: false) == nil)
        #expect(MicrophoneChoice.usable(savedID: builtIn.id, devices: devices, lidClosed: false) == builtIn)
    }

    @Test func aUSBMicIsUsableWithTheLidClosed() {
        #expect(MicrophoneChoice.unavailableReason(usb, lidClosed: true) == nil)
        #expect(MicrophoneChoice.usable(savedID: usb.id, devices: devices, lidClosed: true) == usb)
    }

    /// A saved device that is unplugged isn't swapped for another.
    @Test func aMissingDeviceIsNil() {
        #expect(MicrophoneChoice.usable(savedID: usb.id, devices: [builtIn], lidClosed: false) == nil)
        #expect(MicrophoneChoice.usable(savedID: usb.id, devices: [], lidClosed: false) == nil)
    }

    /// A chosen, connected microphone that doesn't record is never dropped silently: the start notice says why.
    @Test func everyReasonAChosenMicrophoneDoesntRecordIsTold() {
        func issue(_ savedID: String, devices: [MicrophoneDeviceInfo]? = nil, lidClosed: Bool = false,
                   permission: PermissionStatus = .granted, session: MicrophoneSessionState = .open,
                   lostInReady: Bool = false) -> MicrophoneStartIssue? {
            MicrophoneChoice.startIssue(savedID: savedID, devices: devices ?? self.devices, lidClosed: lidClosed,
                                        permission: permission, session: session, lostInReady: lostInReady)
        }
        // It records: nothing to say. Nor for Do Not Record Microphone, or a device gone before Ready opened.
        #expect(issue(usb.id) == nil)
        #expect(issue("", permission: .notDetermined, session: .notOpened) == nil)
        #expect(issue(usb.id, devices: [builtIn], session: .notOpened) == nil)

        #expect(issue(builtIn.id, lidClosed: true, session: .notOpened) == .lidClosed)
        #expect(issue(usb.id, permission: .notDetermined, session: .notOpened) == .noAccessYet)
        #expect(issue(usb.id, permission: .denied, session: .notOpened) == .noAccess)
        #expect(issue(usb.id, session: .failed) == .couldNotOpen)
        // Access granted after Ready left the microphone closed for want of it (the deferred prompt answered, or System
        // Settings): it never failed to open, so it doesn't say it couldn't be opened.
        #expect(issue(usb.id, session: .notOpened) == .grantedLate)
        // Unplugged while Ready was up, whether or not it is listed now; plugged back in and open, it records.
        #expect(issue(usb.id, devices: [builtIn], session: .notOpened, lostInReady: true) == .disconnected)
        #expect(issue(usb.id, session: .notOpened, lostInReady: true) == .disconnected)
        #expect(issue(usb.id, lostInReady: true) == nil)

        // The words, and an OK, except for the lid, which asks whether to go on.
        let unavailable = "The microphone isn't available, so this recording has no microphone audio."
        let told: [(MicrophoneStartIssue, String?)] = [
            (.noAccessYet, "ClearShot doesn't have microphone access yet."),
            (.noAccess, "ClearShot isn't allowed to use the microphone."),
            (.couldNotOpen, "The microphone couldn't be opened."),
            (.grantedLate, "Microphone access came after this recording was set up; the next recording will use it."),
            (.disconnected, "The microphone was disconnected."),
        ]
        for (issue, message) in told {
            #expect(issue.title == unavailable)
            #expect(issue.message == message)
            #expect(issue.buttons == ["OK"])
        }
        #expect(MicrophoneStartIssue.lidClosed.title == MicrophoneChoice.lidClosedReason)
        #expect(MicrophoneStartIssue.lidClosed.message == nil)
        #expect(MicrophoneStartIssue.lidClosed.buttons == ["Continue Without Audio", "Stop"])
        // Ready's message slot says the permission ones before the recording starts.
        #expect(MicrophoneStartIssue.noAccessYet.reason == "ClearShot doesn't have microphone access yet")
        #expect(MicrophoneStartIssue.noAccess.reason == "ClearShot isn't allowed to use the microphone")
        // The reason stays a short line; the message says the next recording will use the microphone.
        #expect(MicrophoneStartIssue.grantedLate.reason == "Microphone access came after this recording was set up")
    }

    /// The lid closed as Ready opened kept the built-in microphone closed: that stays the reason when the lid has opened
    /// since, rather than access that came late. Other devices don't mind the lid.
    @Test func aLidClosedAsReadyOpenedStaysTheReason() {
        func issue(_ savedID: String, lidClosed: Bool, lidClosedInReady: Bool,
                   permission: PermissionStatus = .granted, session: MicrophoneSessionState) -> MicrophoneStartIssue? {
            MicrophoneChoice.startIssue(savedID: savedID, devices: devices, lidClosed: lidClosed,
                                        lidClosedInReady: lidClosedInReady, permission: permission, session: session,
                                        lostInReady: false)
        }
        #expect(issue(builtIn.id, lidClosed: false, lidClosedInReady: true, session: .notOpened) == .lidClosed)
        #expect(issue(builtIn.id, lidClosed: false, lidClosedInReady: true, permission: .notDetermined,
                      session: .notOpened) == .lidClosed)
        #expect(issue(builtIn.id, lidClosed: true, lidClosedInReady: false, session: .notOpened) == .lidClosed)
        // Open in Ready and now: it records, or says why not.
        #expect(issue(builtIn.id, lidClosed: false, lidClosedInReady: false, session: .open) == nil)
        #expect(issue(builtIn.id, lidClosed: false, lidClosedInReady: false, session: .notOpened) == .grantedLate)
        #expect(issue(usb.id, lidClosed: false, lidClosedInReady: true, session: .open) == nil)
        #expect(issue(usb.id, lidClosed: true, lidClosedInReady: true, session: .notOpened) == .grantedLate)
    }
}
