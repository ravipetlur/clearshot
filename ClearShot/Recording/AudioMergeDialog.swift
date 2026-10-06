import AppKit
import CSCore
import CSRecording

/// The question after a recording with both audio tracks and "Audio tracks: Single track": merge them into one track,
/// each at its volume, or keep them separate. An alert, so it comes only once the recording's windows are gone; the
/// volumes go to 200% and start at the last ones merged with; Merge is the default.
enum AudioMergeDialog {
    /// Volume sliders' range, 1 = 100%.
    static let maximumVolume = 2.0

    /// The alert on screen, to dismiss when quitting.
    private static var isShown = false

    /// Asks. Merge returns the two volumes (1 = 100%) and remembers them for next time; Don't Merge (or a dismissal)
    /// returns nil.
    static func ask(preferences: Preferences) -> (mic: Double, system: Double)? {
        let microphone = VolumeSlider(title: "Microphone volume:", value: preferences[Prefs.recordingMergeMicVolume])
        let system = VolumeSlider(title: "System audio volume:", value: preferences[Prefs.recordingMergeSystemVolume])
        let stack = NSStackView(views: [microphone.row, system.row])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 8
        stack.frame = CGRect(origin: .zero, size: stack.fittingSize)

        let alert = NSAlert()
        alert.messageText = "Merge the microphone and system audio into one track, at these volumes:"
        alert.accessoryView = stack
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Don't Merge")
        NSApp.activate()
        isShown = true
        defer { isShown = false }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        preferences[Prefs.recordingMergeMicVolume] = microphone.value
        preferences[Prefs.recordingMergeSystemVolume] = system.value
        return (microphone.value, system.value)
    }

    /// Closes the alert as Don't Merge, if it is up (quitting).
    static func dismiss() {
        if isShown { NSApp.abortModal() }
    }
}

/// A label, a 0–200% slider and the percentage it is at.
private final class VolumeSlider: NSObject {
    let row: NSStackView
    private let slider: NSSlider
    private let percent = NSTextField(labelWithString: "")

    init(title: String, value: Double) {
        slider = NSSlider(value: min(max(value, 0), AudioMergeDialog.maximumVolume) * 100, minValue: 0,
                          maxValue: AudioMergeDialog.maximumVolume * 100, target: nil, action: nil)
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        percent.alignment = .right
        row = NSStackView(views: [label, slider, percent])
        row.orientation = .horizontal
        row.spacing = 8
        super.init()
        slider.target = self
        slider.action = #selector(changed)
        slider.isContinuous = true
        slider.setAccessibilityLabel(title)
        NSLayoutConstraint.activate([
            slider.widthAnchor.constraint(equalToConstant: 160),
            percent.widthAnchor.constraint(equalToConstant: 44),
        ])
        showPercent()
    }

    /// 1 = 100%, in whole percent.
    var value: Double {
        slider.doubleValue.rounded() / 100
    }

    @objc private func changed() {
        showPercent()
    }

    private func showPercent() {
        percent.stringValue = "\(Int(slider.doubleValue.rounded()))%"
    }
}
