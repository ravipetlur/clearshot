import AppKit
import Quartz

/// The borderless window behind one thumbnail. It never activates ClearShot, but it can become key when clicked, so ⌘C,
/// ⌘S, ⌘W, ⌘E and Space reach it.
final class QuickAccessPanel: NSPanel {
    /// ⌘ shortcuts, with whether ⌥ was held.
    var onCommand: ((QuickAccessCommand, Bool) -> Void)?
    /// The file Quick Look shows.
    var previewURL: URL?
    /// Quick Look stopped using this panel as its controller (closed, or another panel took over).
    var onPreviewEnded: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 216, height: 135), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // ClearShot is almost never the active app, so the buttons' help would otherwise never show.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While the name field is being edited, ⌘C, ⌘V and the rest belong to it.
        if firstResponder is NSText { return super.performKeyEquivalent(with: event) }
        // Only ⌘ or ⌘⌥ count; ⌘⇧C and the like are someone else's. Caps Lock, fn and numeric-pad bits are ignored.
        let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard modifiers.subtracting(.option) == .command, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let command: QuickAccessCommand? = switch key {
        case "c": .copy
        case "s": .save
        case "w": .close
        case "e": .annotate
        default: nil
        }
        guard let command, let onCommand else { return super.performKeyEquivalent(with: event) }
        onCommand(command, modifiers.contains(.option))
        return true
    }

    // MARK: Quick Look (Space). QLPreviewPanel asks the key window's responder chain for a controller.

    // The informal protocol's methods are nonisolated in the SDK. AppKit calls them on the main thread.
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { previewURL != nil }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = self }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            onPreviewEnded?()
        }
    }
}

extension QuickAccessPanel: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
