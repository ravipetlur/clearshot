import CSRecording
import Foundation
import Observation
import SwiftUI

/// What one Video Editor window edits: the source's facts, the edit so far and the plan it makes. The bar changes
/// `edit`; the window controller sets the trim and the busy flags.
@Observable
final class VideoEditorState {
    let mode: VideoEditorMode
    let source: VideoSourceInfo
    /// Original, then the resolutions below the source's (`VideoEditPlan.resolutions(for:)`).
    let resolutions: [RecordingMaxResolution]
    /// For a GIF (`.trimGIF`): its file's size and length now, which its estimate scales.
    let gifSize: (bytes: Int64, duration: Double)?
    var edit = VideoEdit()
    /// The player's trimming controls are up.
    var isTrimming = false
    /// A save is running: its export, its question and its write.
    var isSaving = false

    init(mode: VideoEditorMode, source: VideoSourceInfo, gifSize: (bytes: Int64, duration: Double)?) {
        self.mode = mode
        self.source = source
        self.gifSize = gifSize
        resolutions = VideoEditPlan.resolutions(for: source)
    }

    var hasAudio: Bool { !source.audioChannelCounts.isEmpty }

    /// How Save would carry the edit out; `.nothing` while the edit changes nothing.
    var plan: VideoEditPlan { VideoEditPlan.make(edit: edit, source: source) }

    /// Closing, Cancel or quitting would lose something.
    var hasPendingChanges: Bool { plan.path != .nothing }

    /// "About 12.3 MB": the plan's estimate, or for a GIF its size per second for the trimmed length.
    var estimate: String {
        let bytes: Int64
        if mode == .trimGIF, let gifSize {
            let length = plan.timeRange.map { $0.end - $0.start } ?? source.duration
            bytes = FileSizeEstimate.bytes(scaling: gifSize.bytes, from: gifSize.duration, to: length)
        } else {
            bytes = plan.estimatedBytes
        }
        return "About \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }
}

/// The Video Editor's bar under the player: Trim, Quality, Resolution, Mute, Mono and Volume on the left; the size
/// estimate, Cancel and a prominent Save on the right. Mono and Volume need audio, and Mute turns them off. A GIF
/// (`.trimGIF`) has only Trim, the estimate, Cancel and Save. Nothing changes while the player trims or a save runs.
struct VideoEditorBar: View {
    @Bindable var state: VideoEditorState
    let trim: () -> Void
    let cancel: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: trim) {
                Label("Trim", systemImage: "scissors")
            }
            .help("Trim the start and end with the handles")
            if state.mode != .trimGIF {
                Picker("Quality", selection: $state.edit.quality) {
                    ForEach(Self.qualities, id: \.self) { quality in
                        Text(Self.title(of: quality)).tag(quality)
                    }
                }
                .fixedSize()
                .help("The video's bitrate")
                Picker("Resolution", selection: $state.edit.resolution) {
                    ForEach(state.resolutions, id: \.self) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                .fixedSize()
                .help("The video's longer side; it is never made larger")
                Toggle("Mute", isOn: $state.edit.mute)
                    .disabled(!state.hasAudio)
                    .help("Remove the audio")
                Toggle("Mono", isOn: $state.edit.mono)
                    .disabled(!state.hasAudio || state.edit.mute)
                    .help("Mix the audio down to one channel")
                HStack(spacing: 6) {
                    Text("Volume")
                    Slider(value: volume, in: 0...2)
                        .frame(width: 100)
                        .labelsHidden()
                    Text("\(Int((state.edit.volume * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(!state.hasAudio || state.edit.mute)
                .help("The audio's volume, up to 200%; the preview plays up to 100%")
            }
            Spacer(minLength: 12)
            Text(state.estimate)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("The saved video's estimated size")
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .disabled(state.isTrimming || state.isSaving)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// The volume in whole percents, so dragging back to 100% is no change at all.
    private var volume: Binding<Double> {
        Binding(get: { state.edit.volume }, set: { state.edit.volume = ($0 * 100).rounded() / 100 })
    }

    /// The Quality menu's order.
    private static let qualities: [VideoQuality] = [.original, .high, .medium, .low]

    private static func title(of quality: VideoQuality) -> String {
        switch quality {
        case .original: "Original"
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low"
        }
    }
}

/// How far a save's export has come, for its sheet.
@Observable
final class VideoEditorProgress {
    let title: String
    var fraction = 0.0

    init(title: String) {
        self.title = title
    }
}

/// The sheet a save shows while it exports: "Trimming video..." or "Saving video…", a bar, and Cancel, which stops the
/// export and leaves the video as it was.
struct VideoEditorProgressView: View {
    let progress: VideoEditorProgress
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(progress.title)
                .font(.headline)
            ProgressView(value: progress.fraction)
                .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }
}
