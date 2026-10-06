import CoreAudio
import Foundation
import IOKit

/// Read-only looks at the Mac's state that recording needs: the lid, the free space, an input's mute. None of them
/// changes anything. Tests don't call them: what they return depends on this Mac.
public enum SystemProbes {
    /// Whether the MacBook's lid is closed (IOPMrootDomain's "AppleClamshellState"); nil when the Mac reports no lid
    /// state or the value can't be read.
    public static func isLidClosed() -> Bool? {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(rootDomain) }
        let state = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)
        return state?.takeRetainedValue() as? Bool
    }

    /// The bytes free on the volume holding `url`: `volumeAvailableCapacity`, the stricter value (space the system
    /// could purge doesn't count); nil when it can't be read.
    public static func availableCapacity(at url: URL) -> Int64? {
        guard let capacity = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity else {
            return nil
        }
        return Int64(capacity)
    }

    /// Whether the input with this unique ID (`AVCaptureDevice.uniqueID`, which is Core Audio's device UID) is muted:
    /// its input mute is on (`kAudioDevicePropertyMute`) or its input volume is 0, whichever controls it has. Nil when
    /// the device is unknown or has neither.
    public static func isInputMuted(deviceID: String) -> Bool? {
        guard let device = audioDevice(uid: deviceID) else { return nil }
        return isMuted(mute: inputProperty(kAudioDevicePropertyMute, of: device, initial: UInt32(0)),
                       volume: inputProperty(kAudioDevicePropertyVolumeScalar, of: device, initial: Float32(1)))
    }

    /// The rule behind `isInputMuted`, from the input's mute control and volume scalar (nil: the device has none):
    /// muted when either silences the input, so a mute that reads off doesn't hide a volume at 0.
    static func isMuted(mute: UInt32?, volume: Float32?) -> Bool? {
        guard mute != nil || volume != nil else { return nil }
        return mute.map { $0 != 0 } == true || volume == 0
    }

    // MARK: Private

    private static func audioDevice(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size),
                                       uidPointer, &size, &device)
        }
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// An input-scope property of `device`: the main element's, else the first channel's.
    private static func inputProperty<Value: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                                                              of device: AudioObjectID, initial: Value) -> Value? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput,
                                                     mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value = initial
            var size = UInt32(MemoryLayout<Value>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        return nil
    }
}
