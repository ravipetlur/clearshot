import AppKit
import CSCore
import SwiftUI

/// Shows a short message near the cursor for 1.5 s.
final class HUDController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    /// A fade that is already animating can't be cancelled, so it checks it still owns the panel first.
    private var generations = GenerationCounter()

    /// Shows `text` for `duration`, replacing any message shown; returns the message's number, for `hide`.
    @discardableResult
    func show(_ text: String, symbol: String = "checkmark.circle.fill", duration: Duration = .milliseconds(1500)) -> Int {
        hideTask?.cancel()
        let generation = generations.next()
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let host = NSHostingView(rootView: HUDView(text: text, symbol: symbol))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        // A zero-length animation replaces any fade still in flight, so it can't drive alpha back to 0.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self?.fadeOut(generation: generation)
        }
        return generation
    }

    /// Fades out the message `show` numbered `message`, now, while it is still the one shown (a progress message whose
    /// work has finished); a newer message stays.
    func hide(_ message: Int) {
        guard generations.isCurrent(message) else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in await self?.fadeOut(generation: message) }
    }

    private func fadeOut(generation: Int) async {
        guard let panel, generations.isCurrent(generation) else { return }
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }
        // A newer message may have appeared during the fade; leave it on screen.
        guard generations.isCurrent(generation) else { return }
        panel.orderOut(nil)
    }

    private func origin(for size: NSSize) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x + 16, y: mouse.y - size.height - 16)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        return origin
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
