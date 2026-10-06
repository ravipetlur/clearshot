enum SettingsPane: String, CaseIterable, Identifiable {
    case general, wallpaper, screenshots, recording, quickAccess, annotate, shortcuts, advanced, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .wallpaper: "Wallpaper"
        case .screenshots: "Screenshots"
        case .recording: "Screen Recording"
        case .quickAccess: "Quick Access"
        case .annotate: "Annotate"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .wallpaper: "photo"
        case .screenshots: "camera.viewfinder"
        case .recording: "record.circle"
        case .quickAccess: "square.stack"
        case .annotate: "pencil.tip.crop.circle"
        case .shortcuts: "keyboard"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// The panes Settings shows, in the sidebar's order.
    static var available: [SettingsPane] {
        [.general, .wallpaper, .screenshots, .recording, .quickAccess, .annotate, .shortcuts, .advanced, .about]
    }
}
