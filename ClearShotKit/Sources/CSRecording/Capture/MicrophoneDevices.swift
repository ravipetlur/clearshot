import AVFoundation
import CoreAudio

/// The audio inputs a recording can use.
public enum MicrophoneDevices {
    /// The audio inputs, as Ready's microphone list shows them. Discovery only: it needs no permission and shows no
    /// prompt.
    public static func list() -> [MicrophoneDeviceInfo] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { device in
                MicrophoneDeviceInfo(id: device.uniqueID, name: device.localizedName,
                                     isBuiltIn: isBuiltIn(transportType: device.transportType))
            }
    }

    /// The Mac's own microphone: Core Audio's built-in transport type, 'bltn'.
    static func isBuiltIn(transportType: Int32) -> Bool {
        UInt32(bitPattern: transportType) == kAudioDeviceTransportTypeBuiltIn
    }
}
