import Testing
@testable import CSRecording

/// The rule behind `SystemProbes.isInputMuted`, from the values Core Audio reports. The probes themselves aren't called
/// here: what they return depends on this Mac.
struct SystemProbesTests {
    /// A USB headset often has both controls; either one silencing the input means muted.
    @Test func aMuteOnOrAZeroVolumeIsMuted() {
        #expect(SystemProbes.isMuted(mute: 1, volume: 0.8) == true)
        #expect(SystemProbes.isMuted(mute: 0, volume: 0) == true)
        #expect(SystemProbes.isMuted(mute: nil, volume: 0) == true)
        #expect(SystemProbes.isMuted(mute: 1, volume: nil) == true)
    }

    @Test func aDeviceThatHearsIsNotMutedAndOneWithoutControlsIsUnknown() {
        #expect(SystemProbes.isMuted(mute: 0, volume: 0.5) == false)
        #expect(SystemProbes.isMuted(mute: 0, volume: nil) == false)
        #expect(SystemProbes.isMuted(mute: nil, volume: 1) == false)
        #expect(SystemProbes.isMuted(mute: nil, volume: nil) == nil)
    }
}
