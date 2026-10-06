import Foundation

/// A folder left in Recordings at launch, with what could be read from it.
public struct RecoveryCandidate: Sendable, Equatable {
    public let folder: URL
    /// Nil when the folder has no journal or it doesn't decode.
    public let journal: RecordingJournal?
    /// The recording's playable length in seconds, or nil when the file is missing or can't be read.
    public let playableDuration: Double?
    /// How long ago the folder was created.
    public let age: TimeInterval

    public init(folder: URL, journal: RecordingJournal?, playableDuration: Double?, age: TimeInterval) {
        self.folder = folder
        self.journal = journal
        self.playableDuration = playableDuration
        self.age = age
    }
}

public enum RecoveryAction: Sendable, Equatable {
    case recover(RecoveryCandidate)
    case delete(URL)
    /// Left alone for now; a later launch deletes it once it is older than `RecoveryPlanner.unreadableAge`.
    case keep(URL)
    /// Tried `RecoveryPlanner.maximumAttempts` times without being recovered: moved out of the way, files and all
    /// (`RecordingFolders.setAside`), so no launch tries it again.
    case setAside(URL)
}

public struct RecoveryPlan: Sendable, Equatable {
    /// One per candidate, in their order.
    public var actions: [RecoveryAction]
    /// Some recording turned Focus on and never turned it off.
    public var runsFocusOff: Bool
}

/// What launch does with the recordings a crash or a quit left behind.
public enum RecoveryPlanner {
    /// A recording this short or shorter isn't worth recovering.
    public static let minimumDuration = 0.5
    /// A folder whose file can't be read, or that has no journal, is kept this long, then deleted.
    public static let unreadableAge: TimeInterval = 86_400
    /// Launches that try to recover one recording before it is set aside.
    public static let maximumAttempts = 3

    /// A journal and more than half a second of playable video: recover, unless `maximumAttempts` launches already
    /// tried, when it is set aside instead. A journal and less: delete. An unreadable file or no journal: keep while
    /// younger than a day, else delete. Focus Off runs when any journal turned Focus on.
    public static func plan(_ candidates: [RecoveryCandidate]) -> RecoveryPlan {
        let actions = candidates.map { candidate -> RecoveryAction in
            if let journal = candidate.journal, let duration = candidate.playableDuration {
                guard duration > minimumDuration else { return .delete(candidate.folder) }
                return (journal.recoveryAttempts ?? 0) < maximumAttempts ? .recover(candidate) : .setAside(candidate.folder)
            }
            return candidate.age < unreadableAge ? .keep(candidate.folder) : .delete(candidate.folder)
        }
        return RecoveryPlan(actions: actions, runsFocusOff: candidates.contains { $0.journal?.focusTurnedOn == true })
    }
}
