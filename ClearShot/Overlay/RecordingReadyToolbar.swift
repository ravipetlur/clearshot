import AppKit
import CSCapture
import CSCore
import CSRecording

enum RecordingReadyToolbarAction: Equatable {
    case record(RecordingMode)
    /// A pick from the microphone list: a device's unique ID, or "" for Do Not Record Microphone.
    case microphone(String)
    case toggleSystemAudio
    case toggleHighlightClicks
    /// A typed size: only the side that was edited.
    case size(width: Int?, height: Int?)
    case ratio(SelectionRatio)
    case toggleFullscreen
    /// The gear: close the overlay and open Settings › Screen Recording.
    case settings
    /// No field edits any more, so the overlay can take the keys back.
    case editingEnded
}

/// A recording's Ready toolbar, in its decided order: Record Video, Record GIF, the microphone button with its meter,
/// System Audio, Highlight Clicks, a divider, W × H, the ratio, Toggle fullscreen, the gear and the message slot. The
/// mode Return records (the one used last) is the prominent one, and its hover label says so. The microphone and ratio
/// buttons open in-overlay lists (`OverlayListPanel`, `RatioList`), one at a time, with the hover labels off while one
/// is open; the sizes, ratio and fullscreen behave as All-In-One's.
final class RecordingReadyToolbar {
    private enum ID {
        static let recordVideo = "recordVideo"
        static let recordGIF = "recordGIF"
        static let microphone = "microphone"
        static let meter = "microphoneLevel"
        static let systemAudio = "systemAudio"
        static let highlightClicks = "highlightClicks"
        static let ratio = "ratio"
        static let toggleFullscreen = "toggleFullscreen"
        static let settings = "settings"
        /// Microphone list rows: this prefix and the device's unique ID, or `noMicrophone`.
        static let device = "device."
        static let noMicrophone = "noMicrophone"
    }

    private let onAction: (RecordingReadyToolbarAction) -> Void
    private lazy var toolbar = SelectionToolbar { [weak self] action in self?.toolbarAction(action) }
    private lazy var microphoneList = OverlayListPanel { [weak self] id in self?.choseMicrophone(id) }
    private lazy var ratioList = RatioList { [weak self] action in self?.ratioListAction(action) }
    /// What `update` last showed, so the meter can change alone.
    private var items: [SelectionToolbarItem] = []

    init(onAction: @escaping (RecordingReadyToolbarAction) -> Void) {
        self.onAction = onAction
        // A size field taking the keys closes the lists; the overlay doesn't take them back.
        toolbar.onEditingBegan = { [weak self] in
            guard let self else { return }
            microphoneList.close(reportingEditingEnded: false)
            ratioList.close(reportingEditingEnded: false)
            toolbar.showsHoverLabels = true
        }
    }

    /// Shows `model`'s microphone, meter, system audio, Highlight Clicks and ratio, the selection's `size` (points),
    /// whether it fills its display, and the message slot's text.
    func update(model: RecordingReadyModel, size: CGSize, isFullscreen: Bool, message: (text: String, isWarning: Bool)?) {
        let ratio = model.ratio
        let returnRecordsGIF = model.mode == .gif
        var items: [SelectionToolbarItem] = [
            .button(SelectionToolbarButton(id: ID.recordVideo, symbol: "record.circle", title: "Record Video",
                                           hoverLabel: returnRecordsGIF ? "Record Video" : "Record Video (Return)",
                                           isProminent: !returnRecordsGIF)),
            .button(SelectionToolbarButton(id: ID.recordGIF, symbol: "photo.stack", title: "Record GIF",
                                           hoverLabel: returnRecordsGIF ? "Record GIF (Return)" : "Record GIF",
                                           isProminent: returnRecordsGIF)),
            .menuButton(id: ID.microphone, title: nil, symbol: model.microphoneDevice == nil ? "mic.slash" : "mic",
                        hoverLabel: "Microphone"),
        ]
        if let level = model.meterLevel {
            items.append(.meter(id: ID.meter, level: level))
        }
        items += [
            .button(SelectionToolbarButton(id: ID.systemAudio, symbol: model.systemAudio ? "speaker.wave.2" : "speaker.slash",
                                           hoverLabel: "Record System Audio", isOn: model.systemAudio)),
            .button(SelectionToolbarButton(id: ID.highlightClicks, symbol: "cursorarrow.click.2",
                                           hoverLabel: "Highlight Clicks", isOn: model.highlightClicks)),
            .divider,
            .sizeFields(width: Int(size.width.rounded()), height: Int(size.height.rounded())),
            .menuButton(id: ID.ratio, title: ratio == .freeform ? nil : ratio.title, symbol: "aspectratio",
                        hoverLabel: "Aspect ratio"),
            .button(SelectionToolbarButton(id: ID.toggleFullscreen,
                                           symbol: isFullscreen ? "arrow.down.right.and.arrow.up.left"
                                                                : "arrow.up.left.and.arrow.down.right",
                                           hoverLabel: "Toggle fullscreen", isOn: isFullscreen)),
            .button(SelectionToolbarButton(id: ID.settings, symbol: "gearshape", hoverLabel: "Recording Settings")),
        ]
        if let message {
            items.append(.message(message.text, isWarning: message.isWarning))
        }
        self.items = items
        toolbar.update(items)
        ratioList.current = ratio
        microphoneList.update(microphoneRows(model))
    }

    /// The meter's new level, 0…1, with nothing else changed.
    func updateMeter(_ level: Double) {
        guard let index = items.firstIndex(where: { if case .meter = $0 { true } else { false } }) else { return }
        items[index] = .meter(id: ID.meter, level: level)
        toolbar.update(items)
    }

    /// Places the toolbar for `selection` on the overlay `window` of its display, and an open list with it.
    func show(attachedTo window: NSWindow, selection: CGRect, visibleFrame: CGRect) {
        toolbar.show(attachedTo: window, anchoredTo: selection, visibleFrame: visibleFrame)
        placeOpenList()
    }

    /// Hides the toolbar, its hover label and the lists, ending any editing without reporting it.
    func hide() {
        microphoneList.close(reportingEditingEnded: false)
        ratioList.close(reportingEditingEnded: false)
        toolbar.showsHoverLabels = true
        toolbar.hide()
    }

    /// A size field or a custom-ratio field is being edited (the toolbar or the ratio list then has the keys).
    var isEditing: Bool {
        toolbar.isEditing || ratioList.isEditing
    }

    /// The point is over the toolbar or an open list.
    func contains(_ point: CGPoint) -> Bool {
        toolbar.frame.contains(point) || microphoneList.frame.contains(point) || ratioList.frame.contains(point)
    }

    /// A click on the overlay: ends editing in a size field (committing a typed size) and closes an open list. Returns
    /// whether either was under way, in which case the click does nothing else.
    @discardableResult
    func endInteraction() -> Bool {
        let wasEditing = toolbar.isEditing
        toolbar.endEditing()
        let closedList = closeLists()
        return wasEditing || closedList
    }

    /// Closes an open list (Esc, a click outside it). Returns whether one was open.
    @discardableResult
    func closeLists() -> Bool {
        let wasOpen = microphoneList.isOpen || ratioList.isOpen
        microphoneList.close()
        ratioList.close(reportingEditingEnded: true)
        toolbar.showsHoverLabels = true
        return wasOpen
    }

    // MARK: Actions

    private func toolbarAction(_ action: SelectionToolbarAction) {
        switch action {
        case .pressed(id: ID.microphone):
            let wasOpen = microphoneList.isOpen
            closeLists()
            if !wasOpen { open(microphoneList: true) }
        case .pressed(id: ID.ratio):
            let wasOpen = ratioList.isOpen
            closeLists()
            if !wasOpen { open(microphoneList: false) }
        case .pressed(let id):
            closeLists()
            switch id {
            case ID.recordVideo: onAction(.record(.video))
            case ID.recordGIF: onAction(.record(.gif))
            case ID.systemAudio: onAction(.toggleSystemAudio)
            case ID.highlightClicks: onAction(.toggleHighlightClicks)
            case ID.toggleFullscreen: onAction(.toggleFullscreen)
            case ID.settings: onAction(.settings)
            default: break
            }
        case let .sizeCommitted(width, height):
            onAction(.size(width: width, height: height))
        case .editingEnded:
            if !isEditing { onAction(.editingEnded) }
        }
    }

    private func ratioListAction(_ action: RatioList.Action) {
        switch action {
        case .choose(let ratio):
            closeLists()
            onAction(.ratio(ratio))
        case .editingEnded:
            if !isEditing { onAction(.editingEnded) }
        }
    }

    private func choseMicrophone(_ id: String) {
        closeLists()
        onAction(.microphone(id.hasPrefix(ID.device) ? String(id.dropFirst(ID.device.count)) : ""))
    }

    // MARK: Lists

    /// "Do Not Record Microphone", then the devices, the chosen one checked (Do Not Record when it isn't connected); the
    /// built-in microphone with the lid closed can't be chosen and says why.
    private func microphoneRows(_ model: RecordingReadyModel) -> [OverlayListPanel.Row] {
        let chosen = model.devices.first { $0.id == model.microphoneID }
        var rows = [OverlayListPanel.Row(id: ID.noMicrophone, title: "Do Not Record Microphone", isChecked: chosen == nil)]
        guard !model.devices.isEmpty else { return rows }
        rows.append(.divider(id: "divider"))
        for device in model.devices {
            let reason = MicrophoneChoice.unavailableReason(device, lidClosed: model.lidClosed)
            rows.append(OverlayListPanel.Row(id: ID.device + device.id, title: device.name, isChecked: device == chosen,
                                             isEnabled: reason == nil, detail: reason))
        }
        return rows
    }

    private func open(microphoneList opensMicrophone: Bool) {
        toolbar.showsHoverLabels = false
        placeList(microphone: opensMicrophone)
    }

    private func placeOpenList() {
        if microphoneList.isOpen { placeList(microphone: true) }
        if ratioList.isOpen { placeList(microphone: false) }
    }

    private func placeList(microphone: Bool) {
        guard let button = toolbar.screenFrame(ofItem: microphone ? ID.microphone : ID.ratio) else {
            closeLists()
            return
        }
        if microphone {
            microphoneList.show(under: button, toolbar: toolbar)
        } else {
            ratioList.show(under: button, toolbar: toolbar)
        }
    }
}
