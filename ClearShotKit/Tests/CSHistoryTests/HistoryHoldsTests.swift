import CoreGraphics
import Foundation
import Testing
@testable import CSHistory

@MainActor
final class HistoryHoldsTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "history-holds-\(UUID().uuidString)", directoryHint: .isDirectory)
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes an item `age` seconds older than `now` and adds it to `store`.
    func create(_ store: HistoryStore, age: TimeInterval = 0) throws -> HistoryItem {
        let details = HistoryWriter.Details(origin: .capture, captureKind: .selection, displayName: "Shot", savedURL: nil,
                                            scale: 2, appName: nil, isTransparent: false, globalRect: .zero,
                                            createdAt: now.addingTimeInterval(-age))
        let item = try HistoryWriter.create(image(width: 40, height: 20), details: details, root: root)
        store.add(item)
        return item
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test func holdsAreCounted() {
        let holds = HistoryHolds()
        let id = UUID()
        holds.hold(id)
        holds.hold(id)
        #expect(holds.heldIDs == [id])
        holds.release(id)
        #expect(holds.isHeld(id))
        holds.release(id)
        #expect(!holds.isHeld(id))
        #expect(holds.heldIDs.isEmpty)
    }

    @Test func releasingAnUnheldItemDoesNothing() {
        let holds = HistoryHolds()
        var released: [UUID] = []
        holds.onRelease = { released.append($0) }
        let id = UUID()
        holds.release(id)
        holds.hold(id)
        holds.release(id)
        holds.release(id) // one too many
        #expect(released == [id])
        #expect(!holds.isHeld(id))
    }

    @Test func onReleaseRunsOnEveryReleaseAfterTheCountDrops() {
        let holds = HistoryHolds()
        let id = UUID()
        var heldWhenReleased: [Bool] = []
        holds.onRelease = { released in
            #expect(released == id)
            heldWhenReleased.append(holds.isHeld(released))
        }
        holds.hold(id)
        holds.hold(id)
        holds.release(id)
        holds.release(id)
        #expect(heldWhenReleased == [true, false])
    }

    @Test func neverPurgeKeepsAnItemAPinStillHolds() throws {
        let store = HistoryStore(root: root)
        let item = try create(store, age: 1)
        store.holds.onRelease = { [unowned store] _ in store.purge(retention: .never, now: self.now) }
        store.holds.hold(item.id) // the thumbnail
        store.holds.hold(item.id) // the pin
        store.holds.release(item.id) // the thumbnail closes
        #expect(store.item(id: item.id) != nil)
        #expect(exists(item.folder(in: root)))
        store.holds.release(item.id) // the pin closes
        #expect(store.item(id: item.id) == nil)
        #expect(!exists(item.folder(in: root)))
    }

    @Test func purgeAndClearNeverRemoveAHeldItem() throws {
        let store = HistoryStore(root: root)
        let item = try create(store, age: 40 * 86_400)
        store.holds.hold(item.id)
        #expect(store.purge(retention: .oneMonth, now: now) == 0)
        store.clear(now: now)
        #expect(store.items.map(\.id) == [item.id])
        #expect(exists(item.folder(in: root)))
    }

    @Test func aStoreUsesTheHoldsItIsGiven() {
        let holds = HistoryHolds()
        let store = HistoryStore(root: root, holds: holds)
        #expect(store.holds === holds)
    }
}
