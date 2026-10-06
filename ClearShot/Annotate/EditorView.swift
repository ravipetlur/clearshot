import CSAnnotation
import CSCore
import SwiftUI

/// What the editor's buttons do; the window controller supplies them.
struct EditorActions {
    var done: () -> Void
    var save: () -> Void
    var saveAs: (_ closeAfter: Bool) -> Void
    var copy: () -> Void
    var share: (NSView) -> Void
    var printImage: (_ fitOnOnePage: Bool) -> Void
    var raycast: () -> Void
    var pin: () -> Void
    var dragFile: () -> URL?
    var resize: () -> Void
    var focusCanvas: () -> Void
    var takeScreenshot: () -> Void
    var pasteImage: () -> Void
    var chooseImage: () -> Void
    /// Shows or hides the Background panel.
    var toggleBackgroundPanel: () -> Void
    /// The pictures of image-backed background fills, for the screen the editor's window is on now.
    var backgroundPictures: () -> BackgroundPictureSource
    /// Finishes inline text editing. The Background panel's controls call it first: the text's open live change would
    /// otherwise ignore a background command, or take in a style edit.
    var endTextEditing: () -> Void
    /// The user's own background pictures, which the Background panel lists.
    var backgroundLibrary: BackgroundLibrary
    /// Add background…: a picture file chosen in an open panel and copied into `backgroundLibrary`. Its id, or nil when
    /// the open panel was cancelled or the file was refused (the HUD says so).
    var addBackgroundPicture: () -> UUID?
    /// Deletes one of the user's background pictures (documents keep their own copy); the HUD says so when it can't.
    var removeBackgroundPicture: (UUID) -> Void
    /// The desktop picture file of the screen the editor's window is on, for the Background panel's Desktop tiles.
    var desktopPictureURL: () -> URL?
}

/// The editor window's content: tools on top, the canvas with the Background panel beside it while that is open, and
/// the bottom bar.
struct EditorView: View {
    @Bindable var editor: AnnotationEditor
    let canvas: CanvasController
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            ToolStrip(editor: editor, actions: actions)
            Divider()
            PropertyBar(editor: editor, actions: actions)
            Divider()
            HStack(spacing: 0) {
                CanvasContainer(editor: editor, controller: canvas)
                if editor.isBackgroundPanelOpen {
                    Divider()
                    BackgroundPanel(editor: editor, actions: actions)
                        .frame(width: 260)
                }
            }
            Divider()
            BottomBar(editor: editor, canvas: canvas, actions: actions)
        }
    }
}

struct ToolStrip: View {
    @Bindable var editor: AnnotationEditor
    let actions: EditorActions

    var body: some View {
        let keys = editor.preferences[Prefs.annotateToolKeys].resolved
        HStack(spacing: 4) {
            ForEach(EditorTool.allCases) { tool in
                Button {
                    editor.tool = tool
                } label: {
                    symbol(of: .tool(tool))
                }
                .stripButtonLook(isOn: editor.tool == tool)
                .help(helpText(for: .tool(tool), keys: keys))
            }
            // The Background panel isn't a drawing mode: its button is on while the panel is open.
            Button(action: actions.toggleBackgroundPanel) {
                symbol(of: .backgroundPanel)
            }
            .stripButtonLook(isOn: editor.isBackgroundPanelOpen)
            .help(helpText(for: .backgroundPanel, keys: keys))
            .accessibilityLabel(AnnotateKeyTarget.backgroundPanel.title)
            Divider()
                .frame(height: 16)
            AddImageMenu(actions: actions, isEnabled: editor.crop == nil)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func symbol(of target: AnnotateKeyTarget) -> some View {
        Image(systemName: target.symbol)
            .frame(width: 28, height: 24)
            .contentShape(Rectangle())
    }

    /// The tool's or the panel's name and its letter from Settings › Annotate › Tool shortcuts (`keys` is the setting
    /// resolved once).
    private func helpText(for target: AnnotateKeyTarget, keys: [AnnotateKeyTarget: Character]) -> String {
        guard let key = keys[target] else { return target.title }
        return "\(target.title) (\(String(key).uppercased()))"
    }
}

private extension View {
    /// A tool strip button: plain, in the accent colour on a tinted ground while it is on.
    func stripButtonLook(isOn: Bool) -> some View {
        buttonStyle(.plain)
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .background(isOn ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Add Image: another screenshot, the clipboard's image, or an image file, as an image object. Images stay out of Crop
/// & Resize, so `isEnabled` is off while a crop is being edited.
struct AddImageMenu: View {
    let actions: EditorActions
    let isEnabled: Bool

    var body: some View {
        Menu {
            // The Edit menu's names, so each action has one.
            Button("Take Screenshot…", action: actions.takeScreenshot)
                .disabled(!isEnabled)
            Button("Paste Image from Clipboard", action: actions.pasteImage)
                .disabled(!isEnabled)
            Button("Choose Image…", action: actions.chooseImage)
                .disabled(!isEnabled)
        } label: {
            Image(systemName: "photo.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add Image")
        .accessibilityLabel("Add Image")
    }
}

struct BottomBar: View {
    @Bindable var editor: AnnotationEditor
    let canvas: CanvasController
    let actions: EditorActions
    @State private var shareAnchor: NSView?

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Zoom to Fit") { canvas.zoomToFit() }
                Divider()
                ForEach(CanvasController.levels, id: \.self) { level in
                    Button("\(Int(level * 100))%") { canvas.zoom(to: level) }
                }
                Divider()
                // Their shortcuts (⌘+, ⌘−) belong to the View menu.
                Button("Zoom In") { canvas.zoomIn() }
                Button("Zoom Out") { canvas.zoomOut() }
            } label: {
                Text("\(Int((canvas.magnification * 100).rounded()))%").monospacedDigit()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Toggle(isOn: $editor.isCanvasLocked) {
                Image(systemName: editor.isCanvasLocked ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Lock canvas")
            Spacer()
            Button(action: actions.raycast) { Image(systemName: "sparkles") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Send to Raycast AI Chat")
                .help("Send to Raycast AI Chat (⌘R)")
            Button(action: actions.pin) { Image(systemName: "pin") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Pin to the screen")
                .help("Pin to the screen")
            Button {
                if let shareAnchor { actions.share(shareAnchor) }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .background(AnchorView { view in Task { @MainActor in shareAnchor = view } })
            .accessibilityLabel("Share")
            .help("Share")
            DragHandle(file: actions.dragFile)
                .frame(width: 20, height: 20)
                .accessibilityLabel("Drag the image")
            Button("Copy", action: actions.copy)
                .help("Copy the image (⇧⌘C)")
            Menu("Save") {
                Button("Save") { actions.save() }
                Button("Save As…") { actions.saveAs(false) }
                Button("Save As… and Close") { actions.saveAs(true) }
                Divider()
                Button("Print…") { actions.printImage(true) }
                Button("Print on Several Pages…") { actions.printImage(false) }
            } primaryAction: {
                actions.save()
            }
            .fixedSize()
            .help("Save (⌘S). Hold ⌥ while choosing Save As to skip the dialog.")
            Button("Done", action: actions.done)
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(editor.isApplying)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WindowDragArea())
    }
}

/// The bottom bar's empty space drags the window.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
