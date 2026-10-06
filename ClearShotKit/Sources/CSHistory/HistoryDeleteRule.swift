import Foundation

/// Why a History delete can't go ahead.
public enum HistoryDeleteRefusal: Equatable, Sendable {
    /// `count` of the items are open in Annotate.
    case openInAnnotate(count: Int)
    /// An item's thumbnail is busy (a save or an image change is running).
    case busy
}

/// When the History window may delete items, and what it asks first. Deleting removes history items only; saved files
/// aren't touched.
public enum HistoryDeleteRule {
    /// Nil when all of `ids` may be deleted. The delete is all or nothing: one item open in Annotate or busy refuses it
    /// whole, and an item open in Annotate is the reason given over a busy one.
    public static func refusal(for ids: [UUID], editing: Set<UUID>, busy: Set<UUID>) -> HistoryDeleteRefusal? {
        let selected = Set(ids)
        let edited = selected.intersection(editing).count
        if edited > 0 { return .openInAnnotate(count: edited) }
        if !selected.isDisjoint(with: busy) { return .busy }
        return nil
    }

    /// The confirmation alert's text for deleting the items with these display names.
    public static func confirmation(names: [String]) -> (message: String, detail: String) {
        if names.count == 1, let name = names.first {
            return ("Delete “\(name)”?", "It's removed from Capture History. Saved files aren't touched.")
        }
        return ("Delete \(names.count) captures?", "They're removed from Capture History. Saved files aren't touched.")
    }
}
