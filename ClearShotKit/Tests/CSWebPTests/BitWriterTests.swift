import Testing
@testable import CSWebP

struct BitWriterTests {
    @Test func bitsFillEachByteFromTheLeastSignificantEnd() {
        let writer = BitWriter()
        writer.write(0b101, bits: 3)
        writer.write(0b11, bits: 2)
        // The first value takes bits 0-2, the second bits 3-4; the byte is padded with zeros.
        #expect(writer.bytes() == [0b0001_1101])
    }

    @Test func aValueThatCrossesAByteBoundarySplitsLowBitsFirst() {
        let writer = BitWriter()
        writer.write(0xF, bits: 4)
        writer.write(0xAB, bits: 8)
        // Low nibble of the second value (0xB) completes the first byte, its high nibble (0xA) starts the next.
        #expect(writer.bytes() == [0xBF, 0x0A])
    }

    @Test func aZeroBitWriteChangesNothing() {
        let writer = BitWriter()
        writer.write(0, bits: 0)
        #expect(writer.bytes().isEmpty)
        writer.write(1, bits: 1)
        writer.write(0, bits: 0)
        writer.write(1, bits: 1)
        #expect(writer.bytes() == [0b11])
    }

    @Test func aThirtyTwoBitValueIsWrittenLittleEndian() {
        let writer = BitWriter()
        writer.write(0xDEAD_BEEF, bits: 32)
        #expect(writer.bytes() == [0xEF, 0xBE, 0xAD, 0xDE])
    }

    @Test func aThirtyTwoBitValueAfterAnOddBitShiftsEveryByte() {
        let writer = BitWriter()
        writer.write(1, bits: 1)
        writer.write(0xFFFF_FFFF, bits: 32)
        #expect(writer.bytes() == [0xFF, 0xFF, 0xFF, 0xFF, 0x01])
        let other = BitWriter()
        other.write(0, bits: 3)
        other.write(0x8000_0001, bits: 32)
        // 35 bits: the value shifted up by 3 across five bytes.
        #expect(other.bytes() == [0x08, 0x00, 0x00, 0x00, 0x04])
    }

    @Test func bytesPadsTheLastByteButDoesNotEndTheStream() {
        let writer = BitWriter()
        writer.write(0b1, bits: 1)
        #expect(writer.bytes() == [0x01])
        #expect(writer.bytes() == [0x01])
        writer.write(0b1, bits: 1)
        #expect(writer.bytes() == [0b11])
        writer.write(0, bits: 6)
        writer.write(0xAA, bits: 8)
        #expect(writer.bytes() == [0b11, 0xAA])
    }

    @Test func exactMultiplesOfEightBitsAddNoPadByte() {
        let writer = BitWriter()
        writer.write(0x12, bits: 8)
        writer.write(0x3456, bits: 16)
        #expect(writer.bytes() == [0x12, 0x56, 0x34])
    }

    @Test func sixteenSingleBitsMatchOneSixteenBitWrite() {
        let value: UInt32 = 0b1010_0110_0101_1100
        let bitByBit = BitWriter()
        for bit in 0..<16 { bitByBit.write((value >> UInt32(bit)) & 1, bits: 1) }
        let whole = BitWriter()
        whole.write(value, bits: 16)
        #expect(bitByBit.bytes() == whole.bytes())
        #expect(whole.bytes() == [0x5C, 0xA6])
    }

    @Test func theNumberOfBitsWrittenIsTracked() {
        let writer = BitWriter()
        #expect(writer.bitCount == 0)
        writer.write(0, bits: 5)
        writer.write(0, bits: 32)
        #expect(writer.bitCount == 37)
    }

    // MARK: Contract

    @Test func aValueWiderThanItsFieldIsRefused() async {
        // In every build: a too-wide value would otherwise spill into the fields written after it.
        await #expect(processExitsWith: .failure) {
            BitWriter().write(0b100, bits: 2)
        }
        await #expect(processExitsWith: .failure) {
            BitWriter().write(1, bits: 0)
        }
        await #expect(processExitsWith: .failure) {
            BitWriter().write(0, bits: 33)
        }
    }

    @Test func theLargestValueOfEachWidthIsAccepted() {
        let writer = BitWriter()
        for bits in 1...32 { writer.write(UInt32.max >> UInt32(32 - bits), bits: bits) }
        #expect(writer.bitCount == (1...32).reduce(0, +))
    }

    @Test func finishGivesTheBytesThatBytesWould() {
        let finished = BitWriter()
        let peeked = BitWriter()
        for writer in [finished, peeked] {
            writer.write(0b101, bits: 3)
            writer.write(0xBEEF, bits: 16)
        }
        #expect(finished.finish() == peeked.bytes())
        // 0b101, then 0xBEEF from bit 3: its low 5 bits complete byte 0, the next 8 are byte 1, the last 3 byte 2.
        #expect(peeked.bytes() == [0x7D, 0xF7, 0x05])
        #expect(BitWriter().finish().isEmpty)
    }

    @Test(arguments: [0, 1, 5, 8, 13, 24])
    func appendingAWriterIsWritingItsBitsOneByOneFromWhereTheFirstStopped(_ offset: Int) {
        // A stream of 21 bits (a partial last byte) appended after `offset` bits.
        let tail = BitWriter()
        for (value, bits) in [(0b10110, 5), (0x3A5, 10), (0b1, 1), (0b10010, 5)] { tail.write(UInt32(value), bits: bits) }
        #expect(tail.bitCount == 21)

        let direct = BitWriter()
        let appended = BitWriter()
        for writer in [direct, appended] { writer.write(0x5A5A_5A5A & ((1 << UInt32(offset)) - 1), bits: offset) }
        for (value, bits) in [(0b10110, 5), (0x3A5, 10), (0b1, 1), (0b10010, 5)] { direct.write(UInt32(value), bits: bits) }
        appended.append(tail)
        #expect(appended.bitCount == direct.bitCount)
        #expect(appended.bytes() == direct.bytes())
        // Writing can go on afterwards.
        direct.write(0b111, bits: 3)
        appended.write(0b111, bits: 3)
        #expect(appended.bytes() == direct.bytes())
    }

    @Test func appendingAnEmptyWriterChangesNothing() {
        let writer = BitWriter()
        writer.write(0b101, bits: 3)
        writer.append(BitWriter())
        #expect(writer.bitCount == 3)
        #expect(writer.bytes() == [0b101])
    }
}
