import Testing
@testable import CSWebP

struct DistanceCodesTests {
    // MARK: The map

    @Test func theFigureTextHasAHundredAndTwentyEntries() {
        // The transcription itself: a miscopied figure would not have 120 distinct offsets covering the neighbourhood.
        let map = SpecTables.distanceMap
        #expect(map.count == 120)
        #expect(Set(map.map { "\($0.x),\($0.y)" }).count == 120)
        // Same row: up to 8 columns to the left. 1 to 7 rows above: 8 to the left and 7 to the right.
        for entry in map {
            if entry.y == 0 {
                #expect((1...8).contains(entry.x))
            } else {
                #expect((1...7).contains(entry.y) && (-7...8).contains(entry.x))
            }
        }
        #expect(map.filter { $0.y == 0 }.count == 8)
        #expect((1...7).allSatisfy { row in map.filter { $0.y == row }.count == 16 })
    }

    @Test func theEncodersMapIsTheRFCsMapInTheRFCsOrder() {
        #expect(DistanceCodes.neighbourhood.count == 120)
        for (index, expected) in SpecTables.distanceMap.enumerated() {
            let entry = DistanceCodes.neighbourhood[index]
            #expect(entry.x == expected.x && entry.y == expected.y, "code \(index + 1)")
        }
    }

    @Test func theMapMatchesTheRFCsWorkedWords() {
        // "distance code 1 ... the pixel above" and "code 3 the top-left pixel" (section 3.6.2.2.1), and the two ends.
        #expect(DistanceCodes.neighbourhood[0] == (x: 0, y: 1))
        #expect(DistanceCodes.neighbourhood[1] == (x: 1, y: 0))
        #expect(DistanceCodes.neighbourhood[2] == (x: 1, y: 1))
        #expect(DistanceCodes.neighbourhood[3] == (x: -1, y: 1))
        #expect(DistanceCodes.neighbourhood[119] == (x: 8, y: 7))
        #expect(DistanceCodes.neighbourhood[118] == (x: 8, y: 6))
    }

    // MARK: Decoding

    @Test func codesAbove120AreThePlainDistanceOffsetBy120() {
        for code in [121, 122, 200, 1000, 1_048_576] {
            #expect(DistanceCodes.distance(forCode: code, width: 17) == code - 120)
            #expect(SpecTables.distance(forCode: code, width: 17) == code - 120)
        }
    }

    @Test func decodingClampsToOne() {
        // Width 1: (-1, 1) is 0 and (-7, 1) is -6; both read as 1.
        #expect(DistanceCodes.distance(forCode: 4, width: 1) == 1)
        #expect(DistanceCodes.distance(forCode: 10, width: 1) == 1)
        // Width 2: (-2, 1) is 0.
        #expect(DistanceCodes.distance(forCode: 10, width: 2) == 1)
        // Width 100: (0, 1) is 100 and (8, 7) is 708.
        #expect(DistanceCodes.distance(forCode: 1, width: 100) == 100)
        #expect(DistanceCodes.distance(forCode: 120, width: 100) == 708)
    }

    @Test(arguments: [1, 2, 3, 8, 17, 100, 16383])
    func decodingAgreesWithTheRFCForEveryPlaneCode(_ width: Int) {
        for code in 1...120 {
            let expected = SpecTables.distance(forCode: code, width: width)
            #expect(DistanceCodes.distance(forCode: code, width: width) == expected, "code \(code), width \(width)")
        }
    }

    // MARK: Encoding

    @Test(arguments: [1, 2, 3, 8, 100])
    func everyDistanceFrom1To300MapsToACodeThatDecodesToIt(_ width: Int) {
        for distance in 1...300 {
            let code = DistanceCodes.code(forDistance: distance, width: width)
            #expect(SpecTables.distance(forCode: code, width: width) == distance,
                    "distance \(distance), width \(width), code \(code)")
        }
    }

    @Test(arguments: [1, 2, 3, 8, 100, 1001])
    func theChosenCodeIsTheLowestOneThatDecodesToTheDistance(_ width: Int) {
        for distance in 1...(8 * width + 300) {
            let lowest = (1...120).first { SpecTables.distance(forCode: $0, width: width) == distance }
            let code = DistanceCodes.code(forDistance: distance, width: width)
            #expect(code == (lowest ?? distance + 120), "distance \(distance), width \(width)")
        }
    }

    @Test func aDistanceWithoutAPlaneCodeIsOffsetBy120() {
        // Width 100: 150 is neither a (xi, yi) with yi 0, nor 100 +- 8, nor 200 +- 8, ...
        #expect(DistanceCodes.code(forDistance: 150, width: 100) == 270)
        // Beyond the neighbourhood altogether.
        #expect(DistanceCodes.code(forDistance: 1_000, width: 100) == 1_120)
        #expect(DistanceCodes.code(forDistance: DistanceCodes.maxDistance, width: 100) == 1_048_576)
    }

    @Test func narrowImagesUseTheLowestCodeEvenWhereSeveralCollide() {
        // Width 1: distance 1 is code 1 (0, 1); distance 2 is (1, 1) = code 3 (the same distance also arises from
        // (2, 0), (0, 2) and others, which have higher codes).
        #expect(DistanceCodes.code(forDistance: 1, width: 1) == 1)
        #expect(DistanceCodes.code(forDistance: 2, width: 1) == 3)
        // Width 2: (0, 1) is 2, (1, 0) is 1, (1, 1) is 3.
        #expect(DistanceCodes.code(forDistance: 1, width: 2) == 2)
        #expect(DistanceCodes.code(forDistance: 2, width: 2) == 1)
        #expect(DistanceCodes.code(forDistance: 3, width: 2) == 3)
        // Width 8: (0, 1) is 8 and (8, 0) is also 8: the lower code, 1, wins; the row above's (1, 1) is 9.
        #expect(DistanceCodes.code(forDistance: 8, width: 8) == 1)
        #expect(DistanceCodes.code(forDistance: 9, width: 8) == 3)
        #expect(DistanceCodes.code(forDistance: 1, width: 8) == 2)
        // Width 3: (3, 0) and (0, 1) are both 3; code 1 wins.
        #expect(DistanceCodes.code(forDistance: 3, width: 3) == 1)
    }

    @Test func theNeighbourhoodOfAWideImageIsReachedByItsPlaneCodes() {
        let width = 16383
        for (index, offset) in DistanceCodes.neighbourhood.enumerated() {
            let distance = offset.x + offset.y * width
            #expect(DistanceCodes.code(forDistance: distance, width: width) == index + 1)
        }
    }

    // MARK: Prefix coding of lengths and distance codes

    @Test func prefixCodingInvertsTheRFCsDecodingFor1To4096() {
        for value in 1...4096 {
            let (prefix, extraBits, extraValue) = PrefixCoding.encode(value: value)
            #expect(SpecTables.lz77Value(prefix: prefix, extraValue: extraValue) == value, "value \(value)")
            #expect(prefix < 24, "a length's prefix is one of the first 24: value \(value)")
            #expect(extraBits == (prefix < 4 ? 0 : (prefix - 2) >> 1), "value \(value)")
            #expect(extraValue >= 0 && extraValue < 1 << extraBits, "value \(value)")
        }
    }

    @Test func prefixCodingInvertsTheRFCsDecodingForEveryDistanceCode() {
        // Every value up to 70 000, then a stride through to the largest code the format allows.
        var values = Array(1...70_000)
        values += stride(from: 70_001, through: 1_048_576, by: 97)
        values += [524_289, 786_432, 786_433, 1_048_575, 1_048_576]
        for value in values {
            let (prefix, extraBits, extraValue) = PrefixCoding.encode(value: value)
            #expect(SpecTables.lz77Value(prefix: prefix, extraValue: extraValue) == value, "value \(value)")
            #expect(prefix < 40, "value \(value)")
            #expect(extraValue >= 0 && extraValue < 1 << extraBits, "value \(value)")
        }
    }

    @Test func prefixCodingFollowsTable4AtTheRangeEnds() {
        // RFC 9649, Table 4.
        let rows: [(value: Int, prefix: Int, extraBits: Int)] = [
            (1, 0, 0), (2, 1, 0), (3, 2, 0), (4, 3, 0), (5, 4, 1), (6, 4, 1), (7, 5, 1), (8, 5, 1), (9, 6, 2),
            (12, 6, 2), (13, 7, 2), (16, 7, 2), (3072, 22, 10), (3073, 23, 10), (4096, 23, 10),
            (524_289, 38, 18), (786_432, 38, 18), (786_433, 39, 18), (1_048_576, 39, 18),
        ]
        for row in rows {
            let encoded = PrefixCoding.encode(value: row.value)
            #expect(encoded.prefix == row.prefix && encoded.extraBits == row.extraBits, "value \(row.value)")
        }
        // Table 4 prints the range of prefix 23 as starting at 3072, but its pseudocode (which a decoder follows) puts
        // 3072 at the end of prefix 22's 1024 values (2049..3072) and gives prefix 23 the values 3073..4096. The
        // encoder inverts the pseudocode.
        #expect(PrefixCoding.encode(value: 4096).extraValue == 1023)
    }
}
