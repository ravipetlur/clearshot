import Foundation

/// The last copy of a capture ClearShot put on the clipboard: the item, and the pasteboard's change count right after the
/// write. Deleting that capture takes its copy off the clipboard, but never anything copied since.
public struct ClipboardOwnership: Equatable, Sendable {
    public let itemID: UUID
    public let changeCount: Int

    public init(itemID: UUID, changeCount: Int) {
        self.itemID = itemID
        self.changeCount = changeCount
    }

    /// Whether deleting `itemID` clears the clipboard: only when this is that item's copy and the clipboard's change
    /// count is still the recorded one, so nothing (from ClearShot or any other app) has been written to it since.
    public func clears(deleting itemID: UUID, changeCount current: Int) -> Bool {
        self.itemID == itemID && changeCount == current
    }
}
