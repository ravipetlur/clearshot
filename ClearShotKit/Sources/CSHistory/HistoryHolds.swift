import Foundation

/// Which history items something is showing or working on: a thumbnail, an editor, a pin, a running save. Each holder
/// holds its item once and releases it once, so the holds on an item are counted. `HistoryStore.purge` and `clear` never
/// remove a held item.
@MainActor
public final class HistoryHolds {
    private var counts: [UUID: Int] = [:]

    /// Called after every release of a held item, not only the last, with the count already lowered, so it can run the
    /// purge that retention "Never" defers while an item is held.
    public var onRelease: (@MainActor (UUID) -> Void)?

    public init() {}

    public func hold(_ id: UUID) {
        counts[id, default: 0] += 1
    }

    /// Takes away one hold. Releasing an item that isn't held does nothing.
    public func release(_ id: UUID) {
        guard let count = counts[id] else { return }
        counts[id] = count > 1 ? count - 1 : nil
        onRelease?(id)
    }

    public func isHeld(_ id: UUID) -> Bool {
        counts[id] != nil
    }

    public var heldIDs: Set<UUID> {
        Set(counts.keys)
    }
}
