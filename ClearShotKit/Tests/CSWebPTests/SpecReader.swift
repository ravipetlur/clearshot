import Foundation

/// A reader for the pieces of the lossless bitstream the unit tests inspect, written from RFC 9649's description of
/// reading bits and prefix codes. It is an independent check of the writer's bit packing; ImageIO remains the decoder
/// that decides whether a whole file is valid.
struct SpecBitReader {
    let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var bitsRead: Int { position }

    /// Bits are taken from each byte least-significant first, and the first bit read is the lowest of the result.
    mutating func read(_ count: Int) -> Int {
        var value = 0
        for bit in 0..<count {
            let byte = position >> 3
            precondition(byte < bytes.count, "read past the end of the stream")
            value |= Int((bytes[byte] >> UInt8(position & 7)) & 1) << bit
            position += 1
        }
        return value
    }
}

enum SpecReaderError: Error, Equatable {
    case invalid(String)
}

enum SpecPrefixCode {
    static let codeLengthCodeOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

    /// Reads one prefix code's lengths: the simple form, or the normal form with its code-length code. A simple code
    /// gives each listed symbol length 1.
    static func readLengths(_ reader: inout SpecBitReader, alphabetSize: Int) throws -> [UInt8] {
        var lengths = [UInt8](repeating: 0, count: alphabetSize)
        if reader.read(1) == 1 {
            let symbolCount = reader.read(1) + 1
            let firstSymbol = reader.read(reader.read(1) == 1 ? 8 : 1)
            guard firstSymbol < alphabetSize else {
                throw SpecReaderError.invalid("symbol \(firstSymbol) out of range")
            }
            lengths[firstSymbol] = 1
            if symbolCount == 2 {
                let secondSymbol = reader.read(8)
                guard secondSymbol < alphabetSize else {
                    throw SpecReaderError.invalid("symbol \(secondSymbol) out of range")
                }
                lengths[secondSymbol] = 1
            }
            return lengths
        }

        var codeLengthCodeLengths = [UInt8](repeating: 0, count: 19)
        let count = reader.read(4) + 4
        for index in 0..<count { codeLengthCodeLengths[codeLengthCodeOrder[index]] = UInt8(reader.read(3)) }
        let codeLengthCode = try SpecCanonicalCode(lengths: codeLengthCodeLengths)

        var maxSymbol = alphabetSize
        if reader.read(1) == 1 {
            let lengthBits = 2 + 2 * reader.read(3)
            maxSymbol = 2 + reader.read(lengthBits)
            guard maxSymbol <= alphabetSize else { throw SpecReaderError.invalid("max_symbol beyond the alphabet") }
        }

        var symbol = 0
        var previousNonzero = 8
        while symbol < alphabetSize {
            if maxSymbol == 0 { break }
            maxSymbol -= 1
            let token = try codeLengthCode.decode(&reader)
            switch token {
            case 0...15:
                lengths[symbol] = UInt8(token)
                symbol += 1
                if token != 0 { previousNonzero = token }
            case 16, 17, 18:
                let (extraBits, base, value): (Int, Int, Int) = switch token {
                case 16: (2, 3, previousNonzero)
                case 17: (3, 3, 0)
                default: (7, 11, 0)
                }
                let repeatCount = base + reader.read(extraBits)
                guard symbol + repeatCount <= alphabetSize else { throw SpecReaderError.invalid("repeat past the end") }
                for _ in 0..<repeatCount {
                    lengths[symbol] = UInt8(value)
                    symbol += 1
                }
            default:
                throw SpecReaderError.invalid("token \(token)")
            }
        }
        return lengths
    }
}

/// A canonical prefix code built from code lengths and read bit by bit from the code's most significant bit, the way
/// the RFC's decoder walks its tree. One symbol with a non-zero length is a single leaf: it takes zero bits.
struct SpecCanonicalCode {
    private let lengths: [UInt8]
    private let singleSymbol: Int?
    private var firstCode = [Int](repeating: 0, count: 17)
    private var countAtLength = [Int](repeating: 0, count: 17)
    private var firstIndexAtLength = [Int](repeating: 0, count: 17)
    private var symbolsByCode: [Int] = []

    init(lengths: [UInt8]) throws {
        self.lengths = lengths
        let used = lengths.indices.filter { lengths[$0] > 0 }
        singleSymbol = used.count == 1 ? used[0] : nil
        guard !used.isEmpty else { throw SpecReaderError.invalid("a code without symbols") }
        for length in lengths where length > 0 { countAtLength[Int(length)] += 1 }
        var code = 0, index = 0
        for length in 1...16 {
            code = (code + (length > 1 ? countAtLength[length - 1] : 0)) << 1
            firstCode[length] = code
            firstIndexAtLength[length] = index
            index += countAtLength[length]
        }
        symbolsByCode = used.sorted { (lengths[$0], $0) < (lengths[$1], $1) }
        if used.count > 1 {
            // A complete tree: the Kraft sum is exactly one.
            let kraft = used.reduce(0) { $0 + (1 << (16 - Int(lengths[$1]))) }
            guard kraft == 1 << 16 else { throw SpecReaderError.invalid("the code is not a complete tree") }
        }
    }

    func decode(_ reader: inout SpecBitReader) throws -> Int {
        if let singleSymbol { return singleSymbol }
        var code = 0
        for length in 1...16 {
            code = (code << 1) | reader.read(1)
            let offset = code - firstCode[length]
            if offset >= 0, offset < countAtLength[length] {
                return symbolsByCode[firstIndexAtLength[length] + offset]
            }
        }
        throw SpecReaderError.invalid("no symbol for the bits read")
    }
}
