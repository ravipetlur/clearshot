import Foundation
import Synchronization
@testable import CSCore

// Helpers shared by the shortcut tests (the store and the migration).

/// Records every `ShortcutStore.didChange` post on `center`, as the observers of the app would see it.
final class ChangeRecorder: @unchecked Sendable { // The observer token is only touched in init and deinit.
    struct Post: Equatable {
        /// `userInfo["action"]`: the action's raw value, nil when the key is absent.
        let action: String?
        let userInfoCount: Int
        /// What `probe` returned when the notification arrived, to show the write had already happened.
        let seen: ShortcutSpec?
    }

    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?
    private let recorded = Mutex<[Post]>([])

    init(center: NotificationCenter, probe: @escaping @Sendable () -> ShortcutSpec? = { nil }) {
        self.center = center
        token = center.addObserver(forName: ShortcutStore.didChange, object: nil, queue: nil) { [weak self] note in
            let post = Post(action: note.userInfo?["action"] as? String, userInfoCount: note.userInfo?.count ?? 0, seen: probe())
            self?.recorded.withLock { $0.append(post) }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }

    var posts: [Post] { recorded.withLock { $0 } }
}

/// A log of its own in a temporary folder, gone when it is released, so a test can read what was logged without
/// ever reaching the live log in ~/Library/Logs/ClearShot.
final class TemporaryLog: Sendable {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "clearshot-test-log-\(UUID().uuidString)", directoryHint: .isDirectory)
    let sink: FileLogSink
    let logger: AppLogger

    init() {
        sink = FileLogSink(directory: directory)
        logger = AppLogger(category: "hotkeys", sink: sink)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The log's lines so far.
    var lines: [String] {
        guard let text = try? String(contentsOf: sink.currentFileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

/// A logger that writes nowhere: tests that don't read the log use it, so none can reach the live one.
let silentLogger = AppLogger(category: "hotkeys", sink: nil)
