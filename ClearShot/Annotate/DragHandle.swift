import AppKit
import SwiftUI

/// Drag the finished image into any app.
struct DragHandle: NSViewRepresentable {
    let file: () -> URL?

    final class HandleView: NSImageView, NSDraggingSource {
        var file: () -> URL? = { nil }

        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            guard let url = file() else { return }
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            // The file's icon, not the picture: decoding a large screenshot for a drag image would stall the drag.
            let preview = NSRect(x: bounds.midX - 32, y: bounds.midY - 32, width: 64, height: 64)
            item.setDraggingFrame(preview, contents: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
            beginDraggingSession(with: [item], event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }
    }

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.image = NSImage(systemSymbolName: "hand.draw", accessibilityDescription: "Drag the image")
        view.toolTip = "Drag the image into another app"
        view.unregisterDraggedTypes()
        view.file = file
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.file = file
    }
}

/// An NSView to anchor the share picker on.
struct AnchorView: NSViewRepresentable {
    let onCreate: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        onCreate(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
