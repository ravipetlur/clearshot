import CSCore
import CSHistory
import SwiftUI

/// The History window's SwiftUI side: the filter picker and gear menu in the toolbar, and the grid or an empty state.
struct HistoryView: View {
    @Bindable var model: HistoryModel
    let grid: HistoryGrid
    let coordinator: AppCoordinator
    @Environment(Preferences.self) private var prefs
    @State private var confirmingClear = false

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $model.filter) {
                        ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .primaryAction) {
                    settingsMenu
                }
            }
            .clearHistoryConfirmation(isPresented: $confirmingClear, coordinator: coordinator)
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .disabled:
            ContentUnavailableView {
                Label("Capture History is disabled.", systemImage: "clock.badge.xmark")
            } description: {
                Text("Choose how long to keep captures in Settings › Advanced.")
            } actions: {
                Button("Open Settings") { coordinator.showSettings(.advanced) }
            }
        case .noCaptures:
            ContentUnavailableView("No captures yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Screenshots you take appear here."))
        case .noMatches(let filter):
            ContentUnavailableView(filter.noMatchesTitle, systemImage: "line.3.horizontal.decrease.circle")
        case .grid:
            HistoryGridView(grid: grid)
        }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Keep Captures For", selection: prefs.binding(Prefs.historyRetention)) {
                ForEach(HistoryRetention.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Clear History…") { confirmingClear = true }
        } label: {
            Label("History settings", systemImage: "gearshape")
        }
        .help("History settings")
    }
}

private extension HistoryFilter {
    /// The empty state for a filter that matches nothing while history has items.
    var noMatchesTitle: String {
        switch self {
        case .all: "No captures yet"
        case .screenshots: "No screenshots"
        case .videos: "No videos"
        case .gifs: "No GIFs"
        }
    }
}

extension View {
    /// The Clear History confirmation, for Settings › Advanced and the History window's gear menu.
    func clearHistoryConfirmation(isPresented: Binding<Bool>, coordinator: AppCoordinator) -> some View {
        confirmationDialog("Clear capture history?", isPresented: isPresented) {
            Button("Clear History", role: .destructive) { coordinator.clearHistory() }
        } message: {
            Text("Captures with an open thumbnail, editor or pin are kept, and saved files aren't touched. Other captures that were never saved are deleted for good.")
        }
    }
}
