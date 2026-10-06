import AppKit
import CSCore

/// A question or a warning while a recording is on screen (Restart and Delete, and the recording's warnings): a small
/// dark panel near the control bar, a child of the recording's frame window at its level, never key. Nothing modal runs
/// while recording or counting down, and an alert would open under the frame. The first button is the default, in the
/// accent colour; with `suppressible`, "Don't ask again" sits above the buttons. One at a time.
enum RecordingNoticePanel {
    private static var shown: NoticePanel?

    /// A notice is on screen.
    static var isShown: Bool {
        shown != nil
    }

    /// Shows the notice on `window` (the frame window), under `anchor` (the control bar, else the region) or over it
    /// when there's no room, replacing any notice already shown. `completion` gets the index of the button clicked and
    /// whether "Don't ask again" was ticked, once the panel has closed; a notice closed by `close` never calls it.
    static func show(_ title: String, message: String?, buttons: [String], suppressible: Bool, near anchor: CGRect,
                     attachedTo window: NSWindow, completion: @escaping (_ button: Int, _ suppress: Bool) -> Void) {
        close()
        let panel = NoticePanel(title: title, message: message, buttons: buttons, suppressible: suppressible) { button, suppress in
            close()
            completion(button, suppress)
        }
        shown = panel
        panel.show(near: anchor, attachedTo: window)
    }

    /// Closes the notice without an answer: the recording ended under it.
    static func close() {
        shown?.close()
        shown = nil
    }
}

/// The notice's panel and its controls.
private final class NoticePanel {
    static let width: CGFloat = 300
    static let padding: CGFloat = 16

    private let panel = OverlayChildPanel(takesKey: false)
    private let checkbox: NSButton?
    private let onAnswer: (Int, Bool) -> Void

    init(title: String, message: String?, buttons: [String], suppressible: Bool, onAnswer: @escaping (Int, Bool) -> Void) {
        self.onAnswer = onAnswer
        checkbox = suppressible ? FirstMouseButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil) : nil
        panel.hasShadow = true

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        titleLabel.textColor = .white
        var rows: [NSView] = [titleLabel]
        if let message {
            let messageLabel = NSTextField(wrappingLabelWithString: message)
            messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            messageLabel.textColor = .secondaryLabelColor
            rows.append(messageLabel)
        }
        if let checkbox { rows.append(checkbox) }

        // The default on the right, as in an alert.
        let buttonViews = buttons.enumerated().map { index, title in
            let button = FirstMouseButton(title: title, target: nil, action: nil)
            button.tag = index
            button.bezelStyle = .push
            if index == 0 { button.bezelColor = .controlAccentColor }
            return button
        }
        let buttonRow = NSStackView(views: Array(buttonViews.reversed()))
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let trailing = NSStackView()
        trailing.orientation = .horizontal
        trailing.addView(buttonRow, in: .trailing)
        rows.append(trailing)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: rows[rows.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let background = OverlayMaterialView(cornerRadius: 10)
        background.onPointerInside = { NSCursor.arrow.set() }
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: Self.width),
            trailing.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -Self.padding * 2),
        ])
        for label in rows.compactMap({ $0 as? NSTextField }) {
            label.preferredMaxLayoutWidth = Self.width - Self.padding * 2
        }
        panel.contentView = background
        for button in buttonViews {
            button.target = self
            button.action = #selector(answered(_:))
        }
    }

    /// Under `anchor` (or over it), centred on it and inside its screen's visible frame, as a toolbar is placed.
    func show(near anchor: CGRect, attachedTo window: NSWindow) {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let visibleFrame = window.screen?.visibleFrame ?? window.frame
        let frame = ToolbarPlacement.frame(size: size, anchoredTo: anchor, visibleFrame: visibleFrame).frame
        panel.attach(to: window, frame: frame)
    }

    func close() {
        panel.detach()
    }

    @objc private func answered(_ sender: NSButton) {
        onAnswer(sender.tag, checkbox?.state == .on)
    }
}
