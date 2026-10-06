import AppKit
import CSAnnotation
import UniformTypeIdentifiers

/// Save As with a format menu: Annotate's offers every format (ClearShot Project, PNG, JPEG, HEIC, WebP); a
/// screenshot's thumbnail and pin offer the image formats only.
enum SaveAsPanel {
    /// Starts on `format` (the first of `formats` if it isn't one of them); returns the place and the format chosen.
    static func run(name: String, folder: URL, format: AnnotateSaveFormat,
                    formats: [AnnotateSaveFormat] = AnnotateSaveFormat.allCases) -> (url: URL, format: AnnotateSaveFormat)? {
        guard let initial = formats.contains(format) ? format : formats.first else { return nil }
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: formats.map(\.title))
        popup.selectItem(at: formats.firstIndex(of: initial) ?? 0)
        let switcher = FormatSwitcher(panel: panel, formats: formats)
        popup.target = switcher
        popup.action = #selector(FormatSwitcher.formatChanged(_:))
        let stack = NSStackView(views: [NSTextField(labelWithString: "Format:"), popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = stack
        panel.nameFieldStringValue = name
        switcher.apply(initial)
        NSApp.activate()
        let response = panel.runModal()
        withExtendedLifetime(switcher) {}
        guard response == .OK, let url = panel.url else { return nil }
        // The menu lists `formats`, so its index is theirs, not `AnnotateSaveFormat.allCases`'.
        return (url, formats[popup.indexOfSelectedItem])
    }

    /// Keeps the panel's allowed type and the name's extension in step with the format menu.
    private final class FormatSwitcher: NSObject {
        weak var panel: NSSavePanel?
        /// What the menu lists, in its order.
        let formats: [AnnotateSaveFormat]

        init(panel: NSSavePanel, formats: [AnnotateSaveFormat]) {
            self.panel = panel
            self.formats = formats
        }

        @objc func formatChanged(_ sender: NSPopUpButton) {
            apply(formats[sender.indexOfSelectedItem])
        }

        func apply(_ format: AnnotateSaveFormat) {
            guard let panel else { return }
            let type: UTType? = if let imageFormat = format.imageFormat {
                UTType(imageFormat.utType)
            } else {
                UTType(DocumentPackage.typeIdentifier) ?? UTType(filenameExtension: DocumentPackage.fileExtension, conformingTo: .package)
            }
            if let type { panel.allowedContentTypes = [type] }
            // Only a format's own extension is swapped: a name like "Screenshot 2026-10-03 at 14.22.01" has dots of its
            // own.
            let name = panel.nameFieldStringValue as NSString
            let known = Set(AnnotateSaveFormat.allCases.map(\.fileExtension) + ["jpeg"])
            let base = known.contains(name.pathExtension.lowercased()) ? name.deletingPathExtension : name as String
            panel.nameFieldStringValue = "\(base).\(format.fileExtension)"
        }
    }
}
