import Foundation
import Testing
@testable import CSHistory

struct HistoryDeleteRuleTests {
    let a = UUID()
    let b = UUID()

    @Test func anItemOpenInAnnotateRefusesTheWholeDelete() {
        #expect(HistoryDeleteRule.refusal(for: [a, b], editing: [b], busy: []) == .openInAnnotate(count: 1))
        #expect(HistoryDeleteRule.refusal(for: [a, b], editing: [a, b], busy: []) == .openInAnnotate(count: 2))
    }

    @Test func aBusyItemRefusesTheWholeDelete() {
        #expect(HistoryDeleteRule.refusal(for: [a, b], editing: [], busy: [a]) == .busy)
        #expect(HistoryDeleteRule.refusal(for: [a, b], editing: [a], busy: [b]) == .openInAnnotate(count: 1))
    }

    @Test func freeItemsCanBeDeleted() {
        #expect(HistoryDeleteRule.refusal(for: [a, b], editing: [UUID()], busy: [UUID()]) == nil)
        #expect(HistoryDeleteRule.refusal(for: [a], editing: [], busy: []) == nil)
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
