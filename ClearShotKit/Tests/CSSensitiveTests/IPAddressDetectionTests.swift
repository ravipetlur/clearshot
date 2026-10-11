import Testing
@testable import CSSensitive

/// IPv4 and IPv6 addresses, except the ones that name no machine: loopback, the unspecified and broadcast addresses and the
/// documentation ranges.
struct IPAddressDetectionTests {
    func addresses(_ line: String) -> [String] { foundText(line, .ipAddresses) }

    // MARK: IPv4

    @Test(arguments: ["10.0.0.5", "192.168.1.20", "1.2.3.4", "172.16.254.1", "100.64.12.7", "169.254.10.20", "255.255.255.254"])
    func anIPv4AddressIsFound(address: String) {
        #expect(found("host \(address) up", .ipAddresses) == [Found(.ipAddress, address)])
        #expect(found("host \(address) up") == [Found(.ipAddress, address)])
    }

    @Test func anAddressWithAPortOrAMaskIsFoundWithoutIt() {
        #expect(addresses("connect 10.0.0.5:8080") == ["10.0.0.5"])
        #expect(addresses("route 10.0.0.0/24 via 10.0.0.1") == ["10.0.0.0", "10.0.0.1"])
        #expect(addresses("see http://10.0.0.5/path") == ["10.0.0.5"])
        #expect(addresses("at 10.0.0.5.") == ["10.0.0.5"])
    }

    @Test(arguments: [
        "256.1.1.1",
        "1.2.3.256",
        "1.2.3",
        "1.2.3.4.5",
        "999.999.999.999",
        "1.2.3.04",
        "1..2.3",
        "12345.1.1.1",
        "v1.2.3",
        "10.45.12",
    ])
    func anInvalidDottedQuadIsNotFound(text: String) {
        #expect(addresses(text) == [])
    }

    @Test(arguments: [
        "127.0.0.1", "127.0.0.53", "127.255.255.254",
        "0.0.0.0", "255.255.255.255",
        "192.0.2.0", "192.0.2.5", "192.0.2.255",
        "198.51.100.7", "203.0.113.9", "203.0.113.255",
    ])
    func anExcludedAddressIsNotFound(address: String) {
        #expect(addresses("host \(address) up") == [])
    }

    @Test(arguments: ["128.0.0.1", "126.255.255.255", "192.0.1.5", "192.0.3.5", "198.51.99.7", "198.51.101.7", "203.0.112.9", "203.0.114.9", "0.0.0.1", "255.255.255.0"])
    func addressesBesideTheExcludedRangesAreFound(address: String) {
        #expect(addresses("host \(address) up") == [address])
    }

    // MARK: IPv6

    @Test(arguments: [
        "fd12:3456:789a:1:0:0:0:1",
        "fd12:3456:789a:0001:0000:0000:0000:0001",
        "fd12:3456:789a:1::1",
        "fd12:3456::",
        "fe80::1ff:fe23:4567:890a",
        "fe80::1",
        "FE80::ABCD:1",
        "fd12::5",
        "1:2:3:4:5:6:7:8",
        "1::8",
        "fd12:3456:789a::",
        "::ffff:10.0.0.5",
    ])
    func anIPv6AddressIsFound(address: String) {
        #expect(found("host \(address) up", .ipAddresses) == [Found(.ipAddress, address)])
    }

    @Test func anIPv6AddressInBracketsOrAfterAZoneOrAFullStopIsFoundOnItsOwn() {
        #expect(addresses("http://[fd12::5]:8443/") == ["fd12::5"])
        #expect(addresses("link fe80::1%en0 up") == ["fe80::1"])
        #expect(addresses("at fe80::1.") == ["fe80::1"])
        #expect(addresses("at fe80::1: connected") == ["fe80::1"])
    }

    @Test(arguments: [
        "::1", "::", "0:0:0:0:0:0:0:1",
        "2001:db8::1", "2001:0db8:0000:0000:0000:0000:0000:0001", "2001:DB8:abcd::1", "2001:db8::", "2001:db8:1:2:3:4:5:6",
    ])
    func anExcludedIPv6AddressIsNotFound(address: String) {
        #expect(addresses("host \(address) up") == [])
    }

    @Test func theNeighboursOfTheDocumentationPrefixAreFound() {
        #expect(addresses("2001:db9::1") == ["2001:db9::1"])
        #expect(addresses("2001:db7::1") == ["2001:db7::1"])
        #expect(addresses("2002:db8::1") == ["2002:db8::1"])
    }

    @Test(arguments: [
        "10:45:12",
        "12:30",
        "aa:bb:cc:dd:ee:ff",
        "std::vector<int>",
        "Foo::bar()",
        "::add(1)",
        "1:2:3:4:5:6:7:8:9",
        "12345::1",
        "fd12:::1",
        "fd12::1::2",
        "fd12::1g",
        "Time: 10:45",
        "key:value:pair",
    ])
    func textThatIsNotAnIPv6AddressIsNotFound(text: String) {
        #expect(addresses(text) == [])
    }

    @Test func anIPv4AndAnIPv6AddressOnOneLineAreBothFound() {
        #expect(addresses("gateway 10.0.0.1 and fd12::1") == ["10.0.0.1", "fd12::1"])
    }

    @Test func aMappedIPv4AddressIsOneFinding() {
        #expect(found("::ffff:10.0.0.5") == [Found(.ipAddress, "::ffff:10.0.0.5")])
    }
}
