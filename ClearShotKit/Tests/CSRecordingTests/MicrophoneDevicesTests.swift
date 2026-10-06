import Testing
@testable import CSRecording

/// Which inputs are the Mac's own microphone, from Core Audio's transport type (a four-character code). The device
/// list itself isn't read here: it depends on what is plugged in.
struct MicrophoneDevicesTests {
    /// The four-character code as `AVCaptureDevice.transportType` reports it.
    func transportType(_ code: String) -> Int32 {
        Int32(bitPattern: code.utf8.reduce(0) { $0 << 8 | UInt32($1) })
    }

    @Test func bltnIsBuiltIn() {
        #expect(transportType("bltn") == 0x626C_746E)
        #expect(MicrophoneDevices.isBuiltIn(transportType: transportType("bltn")))
    }

    @Test func usbAndVirtualAreNot() {
        for code in ["usb ", "virt", "blue", "aggr"] {
            #expect(!MicrophoneDevices.isBuiltIn(transportType: transportType(code)), "\(code)")
        }
        #expect(!MicrophoneDevices.isBuiltIn(transportType: 0))
    }
}
