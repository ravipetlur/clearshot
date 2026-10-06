import AppKit
import CSCore
import CSRecording

/// What became of a GIF recording's conversion.
enum GIFConversionOutcome {
    /// The GIF, with the intermediate as its source video: routed as a GIF item.
    case gif(RecordingResult)
    /// Stop › Save as a Video: the intermediate, routed as a video.
    case video(RecordingResult)
    /// Stop › Delete: the recording's folder is gone.
    case deleted
    /// The conversion failed (routed as a video), or was cancelled because ClearShot is quitting (the folder stays for
    /// the next launch's recovery).
    case failed(any Error)
}

/// One GIF recording's conversion, after `CaptureFlow.run` has returned: `encoder` turns the intermediate video into
/// `recording.gif` in the recording's folder, reporting its progress, and Stop asks whether to delete the recording or
/// save it as a video instead.
///
/// The question is an alert (the recording's windows are gone by now), shown as a modal moment of the recording's tail
/// (`presentsModally`): it waits for any capture under way, and none starts while it is up. The conversion goes on
/// meanwhile; if it finishes first, the answer still decides. Runs once.
final class GIFConversionJob {
    enum StopAnswer: Equatable {
        case continueConverting, saveAsVideo, delete
    }

    private let folder: RecordingFolder
    /// The intermediate video, as a recording to route.
    private let result: RecordingResult
    private let settings: GIFConversionSettings
    private let encoder: any GIFEncoder

    /// How far the conversion is, 0…1.
    private(set) var progress = 0.0
    /// The GIF's size so far.
    private(set) var bytesWritten: Int64 = 0
    /// Told with each new `progress`, at most ten times a second.
    var onProgress: ((Double) -> Void)?
    /// Runs the Stop question (`ask`) as a modal moment of the recording's tail; the capture flow sets it. On its own the
    /// question just runs.
    var presentsModally: (_ ask: () -> Void) async -> Void = { ask in ask() }

    private var conversion: Task<GIFConversionResult, any Error>?
    /// Save as a Video or Delete, once answered.
    private var decision: StopAnswer?
    private var isAsking = false
    private var answerWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasRun = false
    private var isFinished = false
    private var isCancelledForQuit = false
    /// The Stop question's alert is on screen (to dismiss it when quitting).
    private var isShowingAlert = false

    init(folder: RecordingFolder, result: RecordingResult, settings: GIFConversionSettings, encoder: any GIFEncoder) {
        self.folder = folder
        self.result = result
        self.settings = settings
        self.encoder = encoder
    }

    /// Converts, then says what became of the recording: the GIF, the video (Save as a Video), nothing (Delete), or the
    /// error. A partial GIF never stays behind.
    func run() async -> GIFConversionOutcome {
        guard !hasRun else { return .failed(CancellationError()) }
        hasRun = true
        let (encoder, source, destination, settings) = (encoder, result.fileURL, folder.gifURL, settings)
        // From the encoder's queue, onto the main actor.
        let reportProgress: @Sendable (GIFProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.report(progress) }
        }
        let conversion = Task {
            try await encoder.convert(source, to: destination, settings: settings, progress: reportProgress)
        }
        self.conversion = conversion
        // Stopped or quit before it began.
        if decision != nil || isCancelledForQuit { conversion.cancel() }
        let converted = await conversion.result
        // A question still up decides what happens to what was converted.
        if isAsking {
            await withCheckedContinuation { answerWaiters.append($0) }
        }
        isFinished = true
        switch decision {
        case .delete?:
            Log.recording.info("Deleted the GIF recording during its conversion")
            try? FileManager.default.removeItem(at: folder.url)
            return .deleted
        case .saveAsVideo?:
            Log.recording.info("Stopped the GIF conversion; saving the recording as a video")
            try? FileManager.default.removeItem(at: destination)
            return .video(result)
        case .continueConverting?, nil:
            switch converted {
            case .success(let gif):
                Log.recording.info("Created a GIF of \(gif.frameCount) frames, \(gif.byteCount) bytes")
                return .gif(gifResult(gif))
            case .failure(let error):
                try? FileManager.default.removeItem(at: destination)
                return .failed(error)
            }
        }
    }

    /// Stop (the status item, the progress panel): "Stop creating the GIF?" with Continue, Save as a Video and Delete.
    /// While it is up, another Stop brings it forward.
    func requestStop() {
        guard !isAsking else {
            NSApp.modalWindow?.orderFrontRegardless()
            return
        }
        guard !isFinished, decision == nil else { return }
        isAsking = true
        Task {
            var answer = StopAnswer.continueConverting
            await presentsModally { answer = self.askStop() }
            isAsking = false
            if answer != .continueConverting, !isFinished {
                decision = answer
                conversion?.cancel()
            }
            let waiters = answerWaiters
            answerWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    /// Quitting: the Stop question goes as Continue, and the conversion stops; the recording's folder stays, so the
    /// next launch recovers it as a video.
    func cancelForQuit() {
        isCancelledForQuit = true
        if isShowingAlert { NSApp.abortModal() }
        conversion?.cancel()
    }

    // MARK: Private

    private func report(_ progress: GIFProgress) {
        guard !isFinished, progress.fraction >= self.progress else { return }
        self.progress = progress.fraction
        bytesWritten = progress.bytesWritten
        onProgress?(progress.fraction)
    }

    /// The GIF as a recording: its own size and length, the intermediate kept as its source video.
    private func gifResult(_ gif: GIFConversionResult) -> RecordingResult {
        var routed = result
        routed.fileURL = gif.url
        routed.mode = .gif
        routed.duration = gif.duration
        routed.pixelWidth = gif.pixelWidth
        routed.pixelHeight = gif.pixelHeight
        routed.hasAudio = false
        routed.sourceVideo = result.fileURL
        return routed
    }

    private func askStop() -> StopAnswer {
        let alert = NSAlert()
        alert.messageText = "Stop creating the GIF?"
        alert.informativeText = "Save the recording as a video instead, or delete it."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Save as a Video")
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        NSApp.activate()
        isShowingAlert = true
        defer { isShowingAlert = false }
        switch alert.runModal() {
        case .alertSecondButtonReturn: return .saveAsVideo
        case .alertThirdButtonReturn: return .delete
        default: return .continueConverting
        }
    }
}
