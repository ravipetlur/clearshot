import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel
    let coordinator: AppCoordinator

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.available, selection: $model.selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            let pane = model.selection ?? .general
            detail(for: pane)
                .navigationTitle(pane.title)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    @ViewBuilder
    private func detail(for pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(coordinator: coordinator)
        case .wallpaper: WallpaperPane()
        case .screenshots: ScreenshotsPane()
        case .recording: ScreenRecordingPane(coordinator: coordinator)
        case .quickAccess: QuickAccessPane()
        case .annotate: AnnotatePane()
        case .shortcuts: ShortcutsPane()
        case .advanced: AdvancedPane(coordinator: coordinator)
        case .about: AboutPane()
        }
    }
}
