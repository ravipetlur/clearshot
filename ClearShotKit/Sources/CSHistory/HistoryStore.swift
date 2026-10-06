import CSCore
import Foundation
import Observation

/// A change to the store's items, told to its observers.
public enum HistoryChange: Equatable, Sendable {
    case added(UUID), updated(UUID), removed(UUID)
}

/// Identifies an observer, for `HistoryStore.removeObserver`.
public struct HistoryObserverToken: Hashable, Sendable {
    fileprivate let id = UUID()
}

/// Capture history: one folder per item under `root`. The set of `meta.json` files is the index; items are held in
/// memory, newest first. The app uses the store on the main actor and writes images with `HistoryWriter` off it, into
/// `root`, which is readable anywhere.
///
/// Views observe `items`; everything else that shows an item by ID (a pin, a History cell) observes the changes, which
/// are told synchronously once the change is done, items and folder alike. What shows or works on an item holds it in
/// `holds`, and purging never removes a held item.
@MainActor
@Observable
public final class HistoryStore {
    /// A folder without `meta.json` younger than this may still be being written, so purging leaves it alone.
    public nonisolated static let orphanGracePeriod: TimeInterval = 600

    public nonisolated static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "ClearShot/History", directoryHint: .isDirectory)
    }

    public let root: URL
    public private(set) var items: [HistoryItem]
    @ObservationIgnored public let holds: HistoryHolds
    @ObservationIgnored private var observers: [(token: HistoryObserverToken, handler: @MainActor (HistoryChange) -> Void)] = []

    /// Loads every item folder that has a readable `meta.json`.
    public init(root: URL = HistoryStore.defaultRoot, holds: HistoryHolds = HistoryHolds()) {
        self.root = root
        self.holds = holds
        items = Self.load(from: root)
    }

    public func item(id: UUID) -> HistoryItem? {
        items.first { $0.id == id }
    }

    /// The newest image, for "Annotate Last Screenshot" and "Pin Last Screenshot": videos and GIFs are skipped.
    public var newestScreenshot: HistoryItem? {
        items.first { $0.kind == .screenshot }
    }

    /// Adds an item written by `HistoryWriter`, or replaces the one with the same ID, keeping newest-first order. Tells
    /// observers `.added` for a new ID and `.updated` for a listed one.
    public func add(_ item: HistoryItem) {
        var list = items
        let wasListed = list.contains { $0.id == item.id }
        list.removeAll { $0.id == item.id }
        let index = list.firstIndex { $0.createdAt < item.createdAt } ?? list.endIndex
        list.insert(item, at: index)
        items = list
        notify(wasListed ? .updated(item.id) : .added(item.id))
    }

    /// Re-reads one item's `meta.json`, for when something other than the store changed it (a save that failed partway
    /// has written the flags it set first). The in-memory copy is replaced and the item returned. When the file is
    /// missing or unreadable, memory is left as it is and the result is nil.
    @discardableResult
    public func reload(_ id: UUID) -> HistoryItem? {
        guard let item = Self.loadItem(in: root.appending(path: id.uuidString, directoryHint: .isDirectory)), item.id == id
        else { return nil }
        add(item)
        return item
    }

    /// Saves changed details (a saved path, a new name or size) to `meta.json` and to memory. `modifiedAt` is the
    /// caller's: a metadata change isn't a change to the image.
    public func update(_ item: HistoryItem) throws {
        try HistoryWriter.writeMetadata(item, root: root)
        add(item)
    }

    /// Deletes the item's folder. Files saved elsewhere are not touched. Tells observers `.removed` when the item was
    /// listed.
    public func remove(_ id: UUID) {
        delete(id)
    }

    /// Removes items older than `retention` allows, except held items, and folders an interrupted write left without
    /// `meta.json` (see `removeOrphans`). Folders whose `meta.json` exists but couldn't be read are kept. Returns the
    /// number of items removed.
    @discardableResult
    public func purge(retention: HistoryRetention, now: Date = Date()) -> Int {
        let cutoff = retention.cutoff(now: now)
        let removed = removeUnheld { $0.createdAt < cutoff }
        removeOrphans(now: now)
        return removed
    }

    /// Removes every item except held items.
    public func clear(now: Date = Date()) {
        removeUnheld { _ in true }
        removeOrphans(now: now)
    }

    /// Starts telling `handler` about every change, after the observers already registered. Keep the token to stop.
    ///
    /// The store keeps `handler` strongly until the token is removed, so a handler captures its owner weakly. Events
    /// for one ID can arrive out of order: an observer told of a change can make another (closing a pin releases a
    /// hold, which can purge), and observers later in the list hear of that one first. So a handler looks the item up
    /// by ID (`item(id:)`) rather than trusting the event's order.
    @discardableResult
    public func observe(_ handler: @escaping @MainActor (HistoryChange) -> Void) -> HistoryObserverToken {
        let token = HistoryObserverToken()
        observers.append((token, handler))
        return token
    }

    public func removeObserver(_ token: HistoryObserverToken) {
        observers.removeAll { $0.token == token }
    }

    /// Tells every observer, in registration order. An observer may change the store (closing a pin releases a hold,
    /// which can purge), so this goes through the observers registered now, skipping any removed along the way.
    private func notify(_ change: HistoryChange) {
        for observer in observers where observers.contains(where: { $0.token == observer.token }) {
            observer.handler(change)
        }
    }

    /// Removes the listed items `matching` that aren't held, checking each as it goes, since an observer told of one
    /// removal may hold or remove another item. Returns how many this removed.
    @discardableResult
    private func removeUnheld(where matching: (HistoryItem) -> Bool) -> Int {
        var removed = 0
        for item in items where matching(item) {
            guard !holds.isHeld(item.id), delete(item.id) else { continue }
            removed += 1
        }
        return removed
    }

    /// Deletes the item's folder and forgets it, then tells observers if it was listed. Returns whether it was.
    @discardableResult
    private func delete(_ id: UUID) -> Bool {
        let wasListed = items.contains { $0.id == id }
        if wasListed { items.removeAll { $0.id == id } }
        try? FileManager.default.removeItem(at: root.appending(path: id.uuidString, directoryHint: .isDirectory))
        if wasListed { notify(.removed(id)) }
        return wasListed
    }

    /// Deletes the leftovers of interrupted writes: folders named with a UUID that isn't a loaded item, that have no
    /// `meta.json`, and that are older than the grace period. A folder whose `meta.json` exists is never deleted here,
    /// even if it failed to load (a newer schema or a read error), so history is never lost to a bad read.
    private func removeOrphans(now: Date) {
        let known = Set(items.map(\.id))
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent), !known.contains(id),
                  !FileManager.default.fileExists(atPath: folder.appending(path: HistoryItem.metadataFileName).path(percentEncoded: false))
            else { continue }
            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            guard now.timeIntervalSince(created) > Self.orphanGracePeriod else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }

    nonisolated static func load(from root: URL) -> [HistoryItem] {
        let decoder = JSONDecoder()
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { loadItem(in: $0, decoder: decoder) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The item in one folder: named with its UUID, with a `meta.json` that decodes to the item with that ID.
    private nonisolated static func loadItem(in folder: URL, decoder: JSONDecoder = JSONDecoder()) -> HistoryItem? {
        guard let id = UUID(uuidString: folder.lastPathComponent),
              let data = try? Data(contentsOf: folder.appending(path: HistoryItem.metadataFileName)),
              let item = try? decoder.decode(HistoryItem.self, from: data),
              item.id == id else { return nil }
        return item
    }
}
