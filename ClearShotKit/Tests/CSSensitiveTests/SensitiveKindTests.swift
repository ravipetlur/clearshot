import Testing
@testable import CSSensitive

struct SensitiveKindTests {
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
}
