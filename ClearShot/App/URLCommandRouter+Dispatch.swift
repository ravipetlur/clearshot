import AppKit
import CSAnnotation
import CSAPI
import CSCore
import UniformTypeIdentifiers

/// Each command's entry point. A command that matches a `ClearShotAction` without parameters goes through
/// `AppCoordinator.perform`, so hotkeys, the menu and URLs take one path; the rest call their own entry points.
extension URLCommandRouter {
    /// Runs a checked command: `area` is its area on the screen now and `file` its checked file, when it gives them.
    func dispatch(_ command: APICommand, area: ResolvedAPIArea?, file: URL?, label: String) {
        let flow = coordinator.captureFlow
        switch command {
        case .allInOne:
            if let area {
                // Opened on the area, which isn't remembered as All-In-One's last selection for opening it.
                let initial = SavedArea(rect: area.rect, displayID: area.display.id)
                Task { await flow.allInOne(initial: initial) }
            } else {
                coordinator.perform(.allInOne)
            }
        case let .captureArea(_, action):
            if let area {
                Task { await flow.captureArea(at: area.rect, on: area.display, override: action.map(Self.override)) }
            } else {
                coordinator.perform(action.map(Self.captureAreaAction) ?? .captureArea)
            }
        case .captureAreaForRaycast:
            if let area {
                Task { await flow.captureArea(at: area.rect, on: area.display, override: .raycast) }
            } else {
                coordinator.perform(.captureAreaAndSendToRaycast)
            }
        case let .capturePreviousArea(action):
            if let action {
                Task { await flow.capturePreviousArea(override: Self.override(action)) }
            } else {
                coordinator.perform(.capturePreviousArea)
            }
        case let .captureFullscreen(action):
            if let action {
                Task { await flow.captureFullscreen(override: Self.override(action)) }
            } else {
                coordinator.perform(.captureFullscreen)
            }
        case let .captureWindow(action):
            if let action {
                Task { await flow.captureWindow(override: Self.override(action)) }
            } else {
                coordinator.perform(.captureWindow)
            }
        case let .selfTimer(action):
            if let action {
                Task { await flow.selfTimer(override: Self.override(action)) }
            } else {
                coordinator.perform(.selfTimer)
            }
        case let .scrollingCapture(_, start):
            if let area {
                Task { await flow.scrollingCapture(at: area.rect, on: area.display, start: Self.scrollingStart(start)) }
            } else {
                coordinator.perform(.scrollingCapture)
            }
        case .recordScreen:
            // Never `perform(.recordScreen)`: that is the Record hotkey, which stops a running recording. An outside app
            // must not, so it meets "A capture is already in progress" instead. With an area, Ready on it, not recording.
            if let area {
                Task { await flow.recordScreen(initial: (area.rect, area.display)) }
            } else {
                Task { await flow.recordScreen() }
            }
        case let .captureText(source, keepLineBreaks):
            switch source {
            case .overlay:
                coordinator.perform(Self.captureTextAction(keepLineBreaks))
            case .area:
                if let area {
                    Task { await flow.captureText(at: area.rect, on: area.display, keepLineBreaks: keepLineBreaks) }
                }
            case .file:
                if let file { recognizeText(in: file, keepLineBreaks: keepLineBreaks, label: label) }
            }
        case .pin:
            if let file {
                let pins = coordinator.pins
                Task {
                    guard let picked = await loadImage(file, label: label) else { return }
                    await pins.pin(picked, from: file)
                }
            } else {
                coordinator.perform(.chooseAndPinImage)
            }
        case .openAnnotate:
            if let file { annotate(file, label: label) } else { chooseImageToAnnotate(label: label) }
        case .openFromClipboard:
            // Images to Annotate, video (and GIF) files to Quick Access.
            let annotate = coordinator.annotate
            coordinator.importer.openFromClipboard(placingImages: { annotate.open($0) })
        case .addQuickAccessOverlay:
            if let file { coordinator.importer.open([file]) }
        case .openHistory:
            coordinator.perform(.openCaptureHistory)
        case .restoreRecentlyClosed:
            coordinator.perform(.restoreLastCapture)
        case let .openSettings(tab):
            let pane = tab.flatMap(Self.pane)
            if tab == .cloud { Log.api.info("\(label): ClearShot has no Cloud settings") }
            coordinator.showSettings(pane)
        case .toggleDesktopIcons:
            coordinator.perform(.toggleDesktopIcons)
        case .hideDesktopIcons:
            coordinator.desktopIcons.setHidden(true)
        case .showDesktopIcons:
            coordinator.desktopIcons.setHidden(false)
        case .debugSelfTest:
            #if DEBUG
            coordinator.runCaptureSelfTest()
            #else
            // Release builds parse `debug-selftest` as an unknown command, so it never gets here.
            Log.api.error("\(label): the self-test is in Debug builds only")
            #endif
        }
    }

    /// capture-text with a file: the file is read (`loadImage`), then read for text as Extract Text reads a capture.
    private func recognizeText(in file: URL, keepLineBreaks: Bool?, label: String) {
        let text = coordinator.text
        Task {
            guard let picked = await loadImage(file, label: label) else { return }
            await text.recognizeAndPresent(picked.image, keepLineBreaks: keepLineBreaks)
        }
    }

    /// A project opens in Annotate as it is; an image (`loadImage`) becomes an unsaved history item, recording the file
    /// as its original, that opens in Annotate.
    private func annotate(_ url: URL, label: String) {
        let annotate = coordinator.annotate
        if url.pathExtension.lowercased() == DocumentPackage.fileExtension {
            annotate.open(projectAt: url)
        } else {
            let importer = coordinator.importer
            Task {
                guard let picked = await loadImage(url, label: label) else { return }
                await importer.importImage(picked, from: url) { annotate.open($0) }
            }
        }
    }

    /// A command's checked image file, read and decoded off the main actor: read through one descriptor that is checked
    /// again as it opens (`APIFiles.read`), so a FIFO, a folder or a link to one swapped in since the check is refused
    /// without waiting, and a file kept only in iCloud or on a stalled network volume holds up only this command. Nil
    /// once `fail` has said why.
    private func loadImage(_ file: URL, label: String) async -> ImageInput.Picked? {
        let loaded = await Task.detached(priority: .userInitiated) { () -> Result<ImageInput.Picked?, APIError> in
            Result { () throws(APIError) in ImageInput.load(data: try APIFiles.read(file)) }
        }.value
        switch loaded {
        case .success(let picked?):
            return picked
        case .success(nil):
            fail(label, APIError.couldntOpen(file.lastPathComponent).message)
        case .failure(let error):
            fail(label, error.message)
        }
        return nil
    }

    /// open-annotate without a file: one image or project to annotate, asked as Open… asks (`ImageImporter.openFile`),
    /// so never over a capture or a recording.
    private func chooseImageToAnnotate(label: String) {
        guard coordinator.gate.allowsQuestion() else { return }
        let project = UTType(DocumentPackage.typeIdentifier)
            ?? UTType(filenameExtension: DocumentPackage.fileExtension, conformingTo: .package)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image] + [project].compactMap(\.self)
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to annotate"
        panel.prompt = "Annotate"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        annotate(url, label: label)
    }

    // MARK: Mappings

    private static func override(_ action: APIAction) -> CaptureOverride {
        switch action {
        case .copy: .copy
        case .save: .save
        case .annotate: .annotate
        case .pin: .pin
        }
    }

    /// capture-area's action without an area: the matching Capture Area & … shortcut.
    private static func captureAreaAction(_ action: APIAction) -> ClearShotAction {
        switch action {
        case .copy: .captureAreaAndCopy
        case .save: .captureAreaAndSave
        case .annotate: .captureAreaAndAnnotate
        case .pin: .captureAreaAndPin
        }
    }

    /// `linebreaks` true or false: the With or Without Line Breaks shortcut; nil: the Keep line breaks setting.
    private static func captureTextAction(_ keepLineBreaks: Bool?) -> ClearShotAction {
        switch keepLineBreaks {
        case true?: .captureTextWithLineBreaks
        case false?: .captureTextWithoutLineBreaks
        case nil: .captureText
        }
    }

    /// Ready on the area (nil), or capturing at once: by hand, or with Auto-Scroll down.
    private static func scrollingStart(_ start: APIScrollStart) -> ScrollingStart? {
        switch start {
        case .none: nil
        case .manual: .manual
        case .autoScroll: .auto(.vertical)
        }
    }

    /// The API's tab names onto ClearShot's panes; `cloud` has no pane.
    private static func pane(_ tab: APISettingsTab) -> SettingsPane? {
        switch tab {
        case .general: .general
        case .wallpaper: .wallpaper
        case .shortcuts: .shortcuts
        case .quickaccess: .quickAccess
        case .recording: .recording
        case .screenshots: .screenshots
        case .annotate: .annotate
        case .cloud: nil
        case .advanced: .advanced
        case .about: .about
        }
    }
}
