import Foundation
import Testing
@testable import CSCore

struct ClipboardOwnershipTests {
    @Test func clearsOnlyItsOwnUnchangedCopy() {
        let item = UUID()
        let copy = ClipboardOwnership(itemID: item, changeCount: 41)
        #expect(copy.clears(deleting: item, changeCount: 41))
    }

    @Test func aLaterCopyIsNeverCleared() {
        // Anything written to the clipboard since, by ClearShot or another app, moves the change count on.
        let item = UUID()
        let copy = ClipboardOwnership(itemID: item, changeCount: 41)
        #expect(!copy.clears(deleting: item, changeCount: 42))
    }

    @Test func anotherItemsCopyIsNeverCleared() {
        let copy = ClipboardOwnership(itemID: UUID(), changeCount: 41)
        #expect(!copy.clears(deleting: UUID(), changeCount: 41))
    }
}
