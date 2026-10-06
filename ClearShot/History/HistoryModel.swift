import CSCore
import CSHistory
import Foundation
import Observation

/// What the History window's content area shows.
enum HistoryContent: Equatable {
    /// Retention "Never".
    case disabled
    /// History is empty.
    case noCaptures
    /// History has items, but none of this kind.
    case noMatches(HistoryFilter)
    case grid
}

/// The History window's state. The grid follows the store's change events, which this coalesces: any number of events
/// or filter changes in one main-actor stretch (a purge removes many items) give one refresh on the next turn, with the
/// items that changed in place. The SwiftUI chrome observes the properties.
@Observable
final class HistoryModel {
    /// Kept while ClearShot runs, not stored.
    var filter: HistoryFilter = .all {
        didSet { if filter != oldValue { scheduleRefresh() } }
    }
    /// The items the filter keeps, newest first, as of the last refresh.
    private(set) var visibleIDs: [UUID] = []
    /// History had items at the last refresh.
    private(set) var hasItems = false
    /// The time the relative-time labels are measured from: set on show, then every minute while the window is visible.
    private(set) var now = Date()

    /// Retention "Never" keeps nothing to show.
    var isDisabled: Bool { preferences[Prefs.historyRetention] == .never }

    var content: HistoryContent {
        if isDisabled { return .disabled }
        if !visibleIDs.isEmpty { return .grid }
        // `.all` matches every item; it can look empty only for the turn before a filter change is refreshed.
        return hasItems && filter != .all ? .noMatches(filter) : .noCaptures
    }

    /// The grid's selection, by item: index paths shift as items come and go, so the grid sets it back from this after
    /// every refresh.
    @ObservationIgnored var selection: Set<UUID> = []
    /// Called after each refresh with the items that changed in place and are still visible.
    @ObservationIgnored var onRefresh: ((_ updatedIDs: Set<UUID>) -> Void)?
    /// Called each time `now` moves on.
    @ObservationIgnored var onTick: (() -> Void)?

    private let history: HistoryStore
    private let preferences: Preferences
    @ObservationIgnored private var observer: HistoryObserverToken?
    @ObservationIgnored private var updatedIDs: Set<UUID> = []
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var clock: Task<Void, Never>?

    init(history: HistoryStore, preferences: Preferences) {
        self.history = history
        self.preferences = preferences
        visibleIDs = history.items.filter(filter.includes).map(\.id)
        hasItems = !history.items.isEmpty
        // The store keeps the handler until it is removed, so it captures the model weakly.
        observer = history.observe { [weak self] change in self?.historyChanged(change) }
    }

    isolated deinit {
        if let observer { history.removeObserver(observer) }
        clock?.cancel()
    }

    // MARK: Refreshing

    private func historyChanged(_ change: HistoryChange) {
        if case .updated(let id) = change { updatedIDs.insert(id) }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { [weak self] in self?.refresh() }
    }

    private func refresh() {
        refreshScheduled = false
        let items = history.items
        let ids = items.filter(filter.includes).map(\.id)
        if ids != visibleIDs { visibleIDs = ids }
        if hasItems == items.isEmpty { hasItems = !items.isEmpty }
        let visible = Set(ids)
        let updated = updatedIDs.filter(visible.contains)
        updatedIDs = []
        onRefresh?(updated)
    }

    // MARK: The minute clock

    /// Sets `now` and moves it on every minute until `stopClock`. Starting again restarts it.
    func startClock() {
        clock?.cancel()
        tick()
        clock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    func stopClock() {
        clock?.cancel()
        clock = nil
    }

    private func tick() {
        now = Date()
        onTick?()
    }
}
