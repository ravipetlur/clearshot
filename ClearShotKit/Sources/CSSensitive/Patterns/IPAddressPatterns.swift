import Foundation

/// IPv4 and IPv6 addresses, except the ones that point at no machine of anyone's: loopback, the unspecified and broadcast
/// addresses, and the documentation ranges.
///
/// A version number with four parts ("1.2.3.4") is an address as far as this goes; that is a known false positive.
enum IPAddressPatterns {
    static func spans(in line: String) -> [Range<String.Index>] {
        ipv4Addresses(in: line) + ipv6Addresses(in: line)
    }

    // MARK: IPv4

    private static let octet = #"(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"#
    /// Four octets of 0 to 255 without leading zeros, on their own: not inside a longer number ("12345.1.1.1"), and not
    /// a piece of one with more parts ("1.2.3.4.5").
    private static let ipv4 = NSRegularExpression.fixed(
        #"(?<![0-9])(?<![0-9]\.)(?:"# + octet + #"\.){3}"# + octet + #"(?![0-9])(?!\.[0-9])"#)

    static func ipv4Addresses(in line: String) -> [Range<String.Index>] {
        ipv4.ranges(in: line).filter { range in
            guard let octets = octets(of: line[range]) else { return false }
            return !isExcluded(octets)
        }
    }

    /// The four numbers of a dotted quad, each 0 to 255; nil if `text` is anything else.
    private static func octets(of text: Substring) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy({ (0...255).contains($0) }) ? parts : nil
    }

    /// 127.0.0.0/8, 0.0.0.0, 255.255.255.255 and the documentation ranges 192.0.2.0/24, 198.51.100.0/24 and 203.0.113.0/24.
    private static func isExcluded(_ octets: [Int]) -> Bool {
        switch (octets[0], octets[1], octets[2], octets[3]) {
        case (127, _, _, _): true
        case (0, 0, 0, 0), (255, 255, 255, 255): true
        case (192, 0, 2, _), (198, 51, 100, _), (203, 0, 113, _): true
        default: false
        }
    }

    // MARK: IPv6

    /// A run of hex digits, colons and dots that stands alone: not after a letter, digit, `_`, `:` or `.`, not before a
    /// letter, digit or `_`. Possessive, so a run is taken whole or not at all ("fd12::1g" is nothing, not "fd12::1").
    private static let ipv6Candidate = NSRegularExpression.fixed(#"(?<![0-9A-Za-z_:.])[0-9A-Fa-f:.]++(?![0-9A-Za-z_])"#)

    static func ipv6Addresses(in line: String) -> [Range<String.Index>] {
        ipv6Candidate.ranges(in: line).compactMap { candidate in
            // A full stop or one colon after the address belongs to the sentence ("at fe80::1.", "fe80::1: up").
            var text = line[candidate]
            if text.hasSuffix(".") { text = text.dropLast() }
            if text.hasSuffix(":"), !text.hasSuffix("::") { text = text.dropLast() }
            guard !text.isEmpty, let groups = groups(of: text), !isExcluded(groups) else { return nil }
            return text.startIndex..<text.endIndex
        }
    }

    /// An address has this many groups of 16 bits.
    private static let groupCount = 8
    /// At least this many are written out: "fd12::5", but not "::1", nor the "::add" that starts a call in code.
    private static let minimumWrittenGroups = 2

    /// The eight groups of an IPv6 address written as `text`, or nil if it isn't one: groups of 1 to 4 hex digits
    /// between colons, one `::` standing for a run of zero groups, the last 32 bits possibly as an IPv4 address.
    private static func groups(of text: Substring) -> [UInt16]? {
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2, let head = written(halves[0], endsAddress: halves.count == 1) else { return nil }
        guard halves.count == 2 else {
            return head.count == groupCount ? head : nil
        }
        guard let tail = written(halves[1], endsAddress: true) else { return nil }
        let writtenCount = head.count + tail.count
        guard writtenCount >= minimumWrittenGroups, writtenCount < groupCount else { return nil }
        return head + [UInt16](repeating: 0, count: groupCount - writtenCount) + tail
    }

    /// The groups written in one half of an address ("" is none). The last of the address may be an IPv4 address, two
    /// groups.
    private static func written(_ half: String, endsAddress: Bool) -> [UInt16]? {
        if half.isEmpty { return [] }
        var parts = half.split(separator: ":", omittingEmptySubsequences: false)
        var result: [UInt16] = []
        if endsAddress, let last = parts.last, last.contains(".") {
            guard let octets = octets(of: last) else { return nil }
            result = [UInt16(octets[0] << 8 | octets[1]), UInt16(octets[2] << 8 | octets[3])]
            parts.removeLast()
        }
        var groups: [UInt16] = []
        for part in parts {
            guard (1...4).contains(part.count), let value = UInt16(part, radix: 16) else { return nil }
            groups.append(value)
        }
        return groups + result
    }

    /// ::1 and :: (loopback and unspecified), and the documentation prefix 2001:db8::/32.
    private static func isExcluded(_ groups: [UInt16]) -> Bool {
        if groups[0] == 0x2001, groups[1] == 0x0db8 { return true }
        return groups.dropLast().allSatisfy { $0 == 0 } && groups.last.map { $0 <= 1 } == true
    }
}
