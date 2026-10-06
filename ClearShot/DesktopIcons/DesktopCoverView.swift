import AppKit
import CSCore

/// What a desktop cover shows and takes: the wallpaper filling the display; a double-click, or "Show Desktop Icons"
/// from the right-click menu, to bring the icons back; and files dropped into ~/Desktop.
///
/// A layer-hosting view whose layer shows the provider's own `CGImage`: a 6K desktop picture is about 100 MB decoded, so
/// it is never copied or redrawn.
final class DesktopCoverView: NSView {
    /// A double-click, or "Show Desktop Icons" from the right-click menu.
    var onShowIcons: (() -> Void)?
    private let drops: DesktopDropReceiver

    init(frame: NSRect, drops: DesktopDropReceiver) {
        self.drops = drops
        super.init(frame: frame)
        // Layer-hosting: set the layer before wantsLayer; nothing is drawn with draw(_:).
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        root.contentsGravity = .resizeAspectFill
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        registerForDraggedTypes(DesktopDropReceiver.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The wallpaper, filling the display. A new picture replaces the last at once, without a fade from black.
    var picture: CGImage? {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = picture
            CATransaction.commit()
        }
    }

    // MARK: Mouse

    /// ClearShot isn't active while the cover is clicked, and the panel never activates it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onShowIcons?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let action = ClearShotAction.toggleDesktopIcons
        let menu = NSMenu()
        menu.addItem(.action(action.menuTitle(desktopIconsHidden: true), symbol: action.symbolName) { [weak self] in
            self?.onShowIcons?()
        })
        return menu
    }

    // MARK: Drops

    /// Only pointer moves and modifier changes (⌥) can change the cursor's operation.
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        drops.operation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        drops.operation(for: sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        drops.receive(sender)
    }
}

/// Puts files dropped on a cover into ~/Desktop, as Finder's desktop would: moved on the same volume, copied from
/// another volume or with ⌥, and numbered " 2", " 3"… when the name is taken (`DesktopDrop`). Shared by every cover, so
/// a name given to a file still being copied in isn't given again.
final class DesktopDropReceiver {
    static let draggedTypes: [NSPasteboard.PasteboardType] =
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map(NSPasteboard.PasteboardType.init(rawValue:))

    private let hud: HUDController
    /// The alert naming files kept back reports a drop, so it waits until no capture or recording is under way.
    private let gate: ModalGate
    private let desktop = URL.desktopDirectory
    /// Where a promised file that couldn't reach ~/Desktop is kept, since it may be the only copy. Unlike the drop's
    /// temporary folder, macOS never empties it.
    private static let undeliveredDrops = URL.applicationSupportDirectory.appending(path: "ClearShot/Undelivered Drops",
                                                                                   directoryHint: .isDirectory)
    /// Names given to files still on their way in.
    private var reserved: Set<String> = []
    /// Promised files are called in on this queue, off the main thread.
    private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(hud: HUDController, gate: ModalGate) {
        self.hud = hud
        self.gate = gate
    }

    /// The cursor's operation: the first file's, or for promised files (dragged from Photos or Mail, say) a copy.
    func operation(for drag: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = drag.draggingPasteboard
        let mask = drag.draggingSourceOperationMask
        let operation: DesktopDrop.Operation?
        if let first = fileURLs(on: pasteboard).first {
            operation = self.operation(for: first, mask: mask)
        } else if pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self]) {
            operation = promiseOperation(mask: mask)
        } else {
            operation = nil
        }
        return switch operation {
        case .move: .move
        case .copy: .copy
        case nil: []
        }
    }

    /// Moves or copies each dropped file into ~/Desktop as `DesktopDrop` decides, leaving out any it refuses (one already
    /// on the desktop). False when it takes nothing.
    func receive(_ drag: any NSDraggingInfo) -> Bool {
        let pasteboard = drag.draggingPasteboard
        let urls = fileURLs(on: pasteboard)
        guard urls.isEmpty else {
            let mask = drag.draggingSourceOperationMask
            let files = urls.compactMap { url in operation(for: url, mask: mask).map { (source: url, operation: $0) } }
            guard !files.isEmpty else { return false }
            transfer(files)
            return true
        }
        let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        guard !promises.isEmpty else { return false }
        return receive(promises)
    }

    // MARK: Files

    /// One file on its way into ~/Desktop.
    private nonisolated struct Transfer: Sendable {
        let source: URL
        let destination: URL
        let operation: DesktopDrop.Operation
    }

    private func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func operation(for file: URL, mask: NSDragOperation) -> DesktopDrop.Operation? {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        return DesktopDrop.operation(sameVolume: isOnDesktopVolume(file), optionHeld: NSEvent.modifierFlags.contains(.option),
                                     sourceAllowsMove: mask.contains(.move), sourceAllowsCopy: mask.contains(.copy),
                                     alreadyThere: folder.pathComponents == desktop.standardizedFileURL.pathComponents)
    }

    /// A volume that can't be read counts as another one, so the file is copied and the original stays.
    private func isOnDesktopVolume(_ file: URL) -> Bool {
        guard let volume = volumeIdentifier(of: file), let desktopVolume = volumeIdentifier(of: desktop) else { return false }
        return volume.isEqual(desktopVolume)
    }

    private func volumeIdentifier(of url: URL) -> (any NSObjectProtocol)? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier
    }

    /// Names every file and reserves the names, then moves or copies them off the main thread (a copy from another disk
    /// can take a while), reporting the first that fails.
    private func transfer(_ files: [(source: URL, operation: DesktopDrop.Operation)]) {
        var taken = fileNames(in: desktop).union(reserved)
        let transfers = files.map { file in
            let destination = freeDestination(for: file.source, in: desktop, taken: &taken)
            return Transfer(source: file.source, destination: destination, operation: file.operation)
        }
        let names = transfers.map(\.destination.lastPathComponent)
        reserved.formUnion(names)
        Task {
            let failed = await Task.detached(priority: .userInitiated) { Self.run(transfers) }.value
            reserved.subtract(names)
            if let first = failed.first { showFailure(first.operation, name: first.source.lastPathComponent) }
        }
    }

    /// Moves or copies each file, returning those that failed. A copy that fails partway leaves nothing on the Desktop
    /// (`DesktopDrop.copyItem`).
    private nonisolated static func run(_ transfers: [Transfer]) -> [Transfer] {
        let files = FileManager()
        return transfers.filter { transfer in
            do {
                switch transfer.operation {
                case .move: try files.moveItem(at: transfer.source, to: transfer.destination)
                case .copy: try DesktopDrop.copyItem(at: transfer.source, to: transfer.destination)
                }
                return false
            } catch {
                Log.app.error("Couldn't \(transfer.operation) \(transfer.source.path(percentEncoded: false)) to the Desktop: \(error)")
                return true
            }
        }
    }

    /// `source`'s name in `folder`, numbered when it is in `taken`, which then takes it too. Files and packages keep
    /// their extension after the number; a folder is numbered at the end of its name.
    private func freeDestination(for source: URL, in folder: URL, taken: inout Set<String>) -> URL {
        let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let splitsExtension = !(values?.isDirectory ?? false) || (values?.isPackage ?? false)
        let name = DesktopDrop.destinationName(for: source.lastPathComponent, splitsExtension: splitsExtension, taken: taken)
        taken.insert(name)
        return folder.appending(component: name)
    }

    private func fileNames(in folder: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? [])
    }

    /// Without a `name`, says "a file".
    private func showFailure(_ operation: DesktopDrop.Operation, name: String?) {
        let verb = switch operation {
        case .move: "move"
        case .copy: "copy"
        }
        hud.show("Couldn't \(verb) \(name.map { "“\($0)”" } ?? "a file") to the Desktop",
                 symbol: "exclamationmark.triangle.fill")
    }

    // MARK: Promised files

    /// A promised file is always copied, and refused when the source offers only a move: the file reaches ~/Desktop
    /// only after the drop, so a source told it moved could delete its original before a move here fails.
    private func promiseOperation(mask: NSDragOperation) -> DesktopDrop.Operation? {
        DesktopDrop.operation(sameVolume: false, optionHeld: NSEvent.modifierFlags.contains(.option),
                              sourceAllowsMove: false, sourceAllowsCopy: mask.contains(.copy), alreadyThere: false)
    }

    /// Calls in the promised files on a background queue, into a folder of the drop's own on the desktop's volume, and
    /// moves each into ~/Desktop under a free name as it arrives. The promising app writes under the name it chooses and
    /// may replace a file of that name, so it never writes into ~/Desktop itself.
    private func receive(_ promises: [NSFilePromiseReceiver]) -> Bool {
        guard let folder = try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                        appropriateFor: desktop, create: true) else {
            Log.app.error("Couldn't make a folder for files promised to the Desktop")
            return false
        }
        let drop = PromisedDrop(folder: folder, promises: promises)
        for (index, promise) in promises.enumerated() {
            promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) {
                @Sendable [weak self] url, error in
                Task { @MainActor in self?.promisedFileArrived(url, error: error, promise: index, in: drop) }
            }
        }
        return true
    }

    /// Puts one promised file from the drop's folder into ~/Desktop (`deliver`). One that can't get there is kept
    /// (`keep`). The folder goes once every promised file has arrived or failed, unless a file is still in it, and then
    /// one alert names the files kept back. `promise` is the index in `drop.promises` of the file's promise.
    private func promisedFileArrived(_ url: URL, error: (any Error)?, promise: Int, in drop: PromisedDrop) {
        defer {
            drop.settled += 1
            if drop.isComplete {
                if !drop.keepsFolder { try? FileManager.default.removeItem(at: drop.folder) }
                if !drop.undelivered.isEmpty {
                    let undelivered = drop.undelivered
                    let inUndeliveredDrops = !drop.keepsFolder
                    drop.undelivered = []
                    // After this returns, so the alert's modal session doesn't run inside the file's handling.
                    Task { showUndelivered(undelivered, inUndeliveredDrops: inUndeliveredDrops) }
                }
            }
        }
        if let error {
            // On an error `url` means nothing (NSFilePromiseReceiver), so the HUD names the promise's file instead.
            Log.app.error("A file promised to the Desktop didn't arrive: \(error)")
            let names = drop.promises[promise].fileNames
            showFailure(.copy, name: names.count == 1 ? names[0] : nil)
            return
        }
        var taken = fileNames(in: desktop).union(reserved)
        do {
            try deliver(url, into: desktop, taken: &taken)
        } catch {
            Log.app.error("Couldn't put promised file \(url.lastPathComponent) on the Desktop: \(error)")
            keep(url, in: drop, because: error)
        }
    }

    /// Moves `file` into `folder` under a free name: a rename on one volume. If that fails, copies it under a fresh
    /// name and then removes `file`. A copy that fails partway leaves nothing behind in `folder`
    /// (`DesktopDrop.copyItem`), and `file` stays where it was. Returns where the file went; throws the copy's error.
    @discardableResult
    private func deliver(_ file: URL, into folder: URL, taken: inout Set<String>) throws -> URL {
        let files = FileManager.default
        let moved = freeDestination(for: file, in: folder, taken: &taken)
        do {
            try files.moveItem(at: file, to: moved)
            return moved
        } catch {
            Log.app.error("Couldn't move \(file.lastPathComponent) to \(folder.path(percentEncoded: false)): \(error)")
        }
        // `taken` now holds the name the move was given, so the copy gets a fresh one.
        let copied = freeDestination(for: file, in: folder, taken: &taken)
        try DesktopDrop.copyItem(at: file, to: copied)
        try? files.removeItem(at: file)
        return copied
    }

    /// Keeps a promised file that couldn't reach ~/Desktop, since it may be the only copy: in Undelivered Drops, or, if
    /// it can't be moved there either, in the drop's folder, which then stays.
    private func keep(_ file: URL, in drop: PromisedDrop, because reason: any Error) {
        let name = file.lastPathComponent
        let folder = Self.undeliveredDrops
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var taken = fileNames(in: folder)
            let kept = try deliver(file, into: folder, taken: &taken)
            drop.undelivered.append((name, kept, reason))
        } catch {
            Log.app.error("Couldn't keep \(name) in \(folder.path(percentEncoded: false)), so it stays in "
                          + "\(drop.folder.path(percentEncoded: false)): \(error)")
            drop.keepsFolder = true
            drop.undelivered.append((name, file, reason))
        }
    }

    /// One alert for a drop's files kept back (`DesktopDrop.undeliveredAlert`), giving the first one's reason and
    /// offering to show them in Finder. `inUndeliveredDrops` is false when any is still in the drop's folder. It reports
    /// the drop, so it waits until no capture or recording is under way (`ModalGate.report`).
    private func showUndelivered(_ files: [UndeliveredFile], inUndeliveredDrops: Bool) {
        guard let first = files.first else { return }
        let text = DesktopDrop.undeliveredAlert(names: files.map(\.name), reason: first.reason.localizedDescription,
                                                inUndeliveredDrops: inUndeliveredDrops)
        let kept = files.map(\.kept)
        gate.report {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = text.message
            alert.informativeText = text.detail
            alert.addButton(withTitle: "Show in Finder")
            alert.addButton(withTitle: "OK")
            NSApp.activate()
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting(kept)
            }
        }
    }
}

/// A promised file that couldn't be put in ~/Desktop: the name it came with, where it is kept, and why.
private typealias UndeliveredFile = (name: String, kept: URL, reason: any Error)

/// One drop's promised files, called in to a folder of their own.
private final class PromisedDrop {
    let folder: URL
    let promises: [NSFilePromiseReceiver]
    /// Promised files that arrived or failed.
    var settled = 0
    /// A promised file couldn't be put in ~/Desktop or Undelivered Drops and stays in `folder`, which then stays too.
    var keepsFolder = false
    /// Promised files that couldn't be put in ~/Desktop and haven't been reported yet.
    var undelivered: [UndeliveredFile] = []

    init(folder: URL, promises: [NSFilePromiseReceiver]) {
        self.folder = folder
        self.promises = promises
    }

    /// Every promised file has arrived or failed. The names are known only once the promises are called in; a promise
    /// that lists none leaves its folder to the system's temporary-file cleanup.
    var isComplete: Bool {
        let expected = promises.reduce(0) { $0 + $1.fileNames.count }
        return expected > 0 && settled >= expected
    }
}
