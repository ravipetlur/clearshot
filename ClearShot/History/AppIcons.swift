import AppKit
import CSHistory

/// The small icon beside a History cell's time: the app the capture was taken in, found by bundle ID, or for older
/// items without one, a running app of the same name. Opened files get a document symbol and clipboard images a
/// clipboard symbol; anything else has none. Only icons found are cached, so an app installed later is still found.
final class AppIcons {
    private var byBundleID: [String: NSImage] = [:]
    private var byName: [String: NSImage] = [:]
    private let documentSymbol = NSImage(systemSymbolName: "doc", accessibilityDescription: "Opened file")
    private let clipboardSymbol = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")

    func icon(for item: HistoryItem) -> NSImage? {
        if let bundleID = item.appBundleID, !bundleID.isEmpty, let icon = appIcon(bundleID: bundleID) { return icon }
        if let name = item.appName, !name.isEmpty, let icon = runningAppIcon(named: name) { return icon }
        return switch item.origin {
        case .file: documentSymbol
        case .clipboard: clipboardSymbol
        case .capture: nil
        }
    }

    private func appIcon(bundleID: String) -> NSImage? {
        if let icon = byBundleID[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        byBundleID[bundleID] = icon
        return icon
    }

    private func runningAppIcon(named name: String) -> NSImage? {
        if let icon = byName[name] { return icon }
        guard let icon = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name })?.icon
        else { return nil }
        byName[name] = icon
        return icon
    }
}
