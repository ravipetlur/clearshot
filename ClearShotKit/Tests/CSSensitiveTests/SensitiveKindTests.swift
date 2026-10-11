import Testing
@testable import CSSensitive

struct SensitiveKindTests {
    @Test func everyKindIsNamedAsSettingsNamesIt() {
        #expect(SensitiveKind.contact.title == "Contact details")
        #expect(SensitiveKind.keyOrToken.title == "Keys and tokens")
        #expect(SensitiveKind.card.title == "Card numbers")
        #expect(SensitiveKind.ipAddress.title == "IP addresses")
        #expect(Set(SensitiveKind.allCases.map(\.title)).count == SensitiveKind.allCases.count)
    }

    @Test func allIsTheFourKinds() {
        #expect(SensitiveKinds.all == [.contact, .keysAndTokens, .cards, .ipAddresses])
        let rawValues = [SensitiveKinds.contact, .keysAndTokens, .cards, .ipAddresses].map(\.rawValue)
        #expect(Set(rawValues).count == 4)
        #expect(SensitiveKinds.all.rawValue == rawValues.reduce(0, |))
    }

    @Test func aKeyOrTokenIsTheMostSpecificKind() {
        let byRank = SensitiveKind.allCases.sorted { $0.specificity > $1.specificity }
        #expect(byRank == [.keyOrToken, .card, .ipAddress, .contact])
    }

    // MARK: Settings' switches

    @Test func eachKindHasItsOwnSwitchAndTheFourMakeAll() {
        let options = SensitiveKind.allCases.map(\.option)
        #expect(options == [.contact, .keysAndTokens, .cards, .ipAddresses])
        #expect(options.reduce(SensitiveKinds(), { $0.union($1) }) == .all)
        // One bit each: no switch turns on two kinds.
        #expect(options.allSatisfy { $0.rawValue.nonzeroBitCount == 1 })
    }

    @Test func eachSwitchHasOneLineExplainingIt() {
        #expect(SensitiveKind.contact.explanation == "Email addresses and phone numbers.")
        #expect(SensitiveKind.keyOrToken.explanation == "API keys, access tokens, passwords and private keys.")
        #expect(SensitiveKind.card.explanation == "Payment card numbers.")
        #expect(SensitiveKind.ipAddress.explanation == "IPv4 and IPv6 addresses, except localhost and example ranges.")
        for kind in SensitiveKind.allCases {
            #expect(!kind.explanation.contains("\n"), "\(kind) is one line")
        }
    }
}
