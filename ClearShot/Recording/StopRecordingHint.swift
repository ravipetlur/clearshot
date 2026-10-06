import AppKit

/// "Press to stop recording" under the menu bar icon, the first time a recording starts: a small dark label with an
/// arrow up to the icon, for a few seconds. It sits at the recording frame's level, above its dimming, and lets clicks
/// through to the icon.
enum StopRecordingHint {
    static let text = "Press to stop recording"

    private static var panel: NSPanel?
    private static var hideTask: Task<Void, Never>?

    /// Shows the hint centred under `button` (the icon's frame, global points) for `duration`.
    static func show(below button: CGRect, for duration: Duration = .seconds(4)) {
        close()
        let label = NSTextField(labelWithString: text)
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .white
        let arrow = NSImageView(image: NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil) ?? NSImage())
        arrow.contentTintColor = .white
        arrow.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let row = NSStackView(views: [arrow, label])
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 12)
        let size = row.fittingSize

        let background = NSView(frame: CGRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.8).cgColor
        background.layer?.cornerRadius = size.height / 2
        background.layer?.cornerCurve = .continuous
        row.frame = background.bounds
        background.addSubview(row)

        let screenFrame = NSScreen.screens.first { $0.frame.intersects(button) }?.visibleFrame ?? button
        let x = min(max(button.midX - size.width / 2, screenFrame.minX + 8), screenFrame.maxX - 8 - size.width)
        let frame = CGRect(x: x.rounded(), y: (button.minY - 6 - size.height).rounded(), width: size.width, height: size.height)
        let hint = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hint.level = .screenSaver
        hint.isOpaque = false
        hint.backgroundColor = .clear
        hint.hasShadow = true
        hint.ignoresMouseEvents = true
        hint.hidesOnDeactivate = false
        hint.isReleasedWhenClosed = false
        hint.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hint.contentView = background
        hint.orderFrontRegardless()
        panel = hint
        hideTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            close()
        }
    }

    static func close() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
