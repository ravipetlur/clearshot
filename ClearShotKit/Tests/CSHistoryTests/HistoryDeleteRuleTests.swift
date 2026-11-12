import Foundation
import Testing
@testable import CSHistory

struct HistoryDeleteRuleTests {
    /// Items, by their place in this list.
    private static let ids = (0..<4).map { _ in UUID() }

    @Test(arguments: [
        // An item open in Annotate refuses the whole delete.
        ([0, 1], [1], [], HistoryDeleteRefusal.openInAnnotate(count: 1)),
        ([0, 1], [0, 1], [], .openInAnnotate(count: 2)),
        // So does a busy one; one open in Annotate is the refusal given.
        ([0, 1], [], [0], .busy),
        ([0, 1], [0], [1], .openInAnnotate(count: 1)),
        // Free items can be deleted.
        ([0, 1], [2], [3], nil),
        ([0], [], [], nil),
    ] as [([Int], [Int], [Int], HistoryDeleteRefusal?)])
    func anItemOpenInAnnotateOrBusyRefusesTheWholeDelete(items: [Int], editing: [Int], busy: [Int], refusal: HistoryDeleteRefusal?) {
        func ids(_ places: [Int]) -> [UUID] { places.map { Self.ids[$0] } }
        #expect(HistoryDeleteRule.refusal(for: ids(items), editing: Set(ids(editing)), busy: Set(ids(busy))) == refusal)
    }

    @Test func confirmationNamesOneItemAndCountsSeveral() {
        let one = HistoryDeleteRule.confirmation(names: ["Shot"])
        #expect(one.message == "Delete “Shot”?")
        #expect(one.detail == "It's removed from Capture History. Saved files aren't touched.")
        let several = HistoryDeleteRule.confirmation(names: ["One", "Two", "Three"])
        #expect(several.message == "Delete 3 captures?")
        #expect(several.detail == "They're removed from Capture History. Saved files aren't touched.")
    }
}
