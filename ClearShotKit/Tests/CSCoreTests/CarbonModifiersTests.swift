import Testing
@testable import CSCore

struct CarbonModifiersTests {
    /// NSEvent.ModifierFlags raw values (NSEvent.h): shift 1 << 17, control 1 << 18, option 1 << 19, command 1 << 20.
    private static let shiftFlag: UInt = 1 << 17
    private static let controlFlag: UInt = 1 << 18
    private static let optionFlag: UInt = 1 << 19
    private static let commandFlag: UInt = 1 << 20

    /// All 16 combinations as (the event flags, the Carbon mask).
    private static let combinations: [(flags: UInt, carbon: Int)] = (0..<16).map { bits in
        var flags: UInt = 0
        var carbon = 0
        if bits & 1 != 0 { flags |= commandFlag; carbon |= ShortcutSpec.command }
        if bits & 2 != 0 { flags |= shiftFlag; carbon |= ShortcutSpec.shift }
        if bits & 4 != 0 { flags |= optionFlag; carbon |= ShortcutSpec.option }
        if bits & 8 != 0 { flags |= controlFlag; carbon |= ShortcutSpec.control }
        return (flags, carbon)
    }

    @Test func eachEventFlagMapsToItsCarbonBit() {
        #expect(CarbonModifiers.from(eventFlags: Self.commandFlag) == 256)
        #expect(CarbonModifiers.from(eventFlags: Self.shiftFlag) == 512)
        #expect(CarbonModifiers.from(eventFlags: Self.optionFlag) == 2048)
        #expect(CarbonModifiers.from(eventFlags: Self.controlFlag) == 4096)
        #expect(CarbonModifiers.from(eventFlags: 0) == 0)
        #expect(CarbonModifiers.from(eventFlags: Self.shiftFlag | Self.commandFlag) == 768)
    }

    @Test func eachCarbonBitMapsToItsEventFlag() {
        #expect(CarbonModifiers.eventFlags(from: 256) == Self.commandFlag)
        #expect(CarbonModifiers.eventFlags(from: 512) == Self.shiftFlag)
        #expect(CarbonModifiers.eventFlags(from: 2048) == Self.optionFlag)
        #expect(CarbonModifiers.eventFlags(from: 4096) == Self.controlFlag)
        #expect(CarbonModifiers.eventFlags(from: 0) == 0)
        #expect(CarbonModifiers.eventFlags(from: 768) == Self.shiftFlag | Self.commandFlag)
    }

    @Test func allSixteenCombinationsConvertBothWays() {
        #expect(Self.combinations.count == 16)
        for (flags, carbon) in Self.combinations {
            #expect(CarbonModifiers.from(eventFlags: flags) == carbon, "flags \(flags)")
            #expect(CarbonModifiers.eventFlags(from: carbon) == flags, "carbon \(carbon)")
        }
    }

    @Test func allSixteenCombinationsRoundTrip() {
        for (flags, carbon) in Self.combinations {
            #expect(CarbonModifiers.eventFlags(from: CarbonModifiers.from(eventFlags: flags)) == flags)
            #expect(CarbonModifiers.from(eventFlags: CarbonModifiers.eventFlags(from: carbon)) == carbon)
        }
    }

    @Test func otherEventFlagBitsAreIgnored() {
        let capsLock: UInt = 1 << 16
        let numericPad: UInt = 1 << 21
        let help: UInt = 1 << 22
        let function: UInt = 1 << 23
        let junk: UInt = 0xFFFF // the device-dependent bits below the flags
        let others = capsLock | numericPad | help | function | junk
        #expect(CarbonModifiers.from(eventFlags: others) == 0)
        for (flags, carbon) in Self.combinations {
            #expect(CarbonModifiers.from(eventFlags: flags | others) == carbon, "flags \(flags)")
        }
        // A real arrow key press: Fn and the numeric-pad bit come with it.
        #expect(CarbonModifiers.from(eventFlags: function | numericPad | Self.controlFlag) == ShortcutSpec.control)
    }

    @Test func otherCarbonBitsAreIgnored() {
        let alphaLock = 1024 // alphaLock
        let rightShift = 0x2000 // rightShiftKey
        let fn = 1 << 17 // Fn, which Carbon sets for arrow and function keys
        let others = alphaLock | rightShift | fn
        #expect(CarbonModifiers.eventFlags(from: others) == 0)
        #expect(CarbonModifiers.eventFlags(from: others | 256) == Self.commandFlag)
        #expect(CarbonModifiers.eventFlags(from: -1) == Self.commandFlag | Self.shiftFlag | Self.optionFlag | Self.controlFlag)
    }
}
