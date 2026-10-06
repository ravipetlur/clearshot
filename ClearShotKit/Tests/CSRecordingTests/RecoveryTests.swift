import AVFoundation
import CoreGraphics
import CSCapture
import Foundation
import Testing
@testable import CSRecording

extension MediaTests {
    /// Recovering an interrupted recording, and the Recordings folder, in a temporary root.
    final class RecoveryTests {
        typealias Media = SyntheticMedia

        let root = FileManager.default.temporaryDirectory.appending(path: "recordings-\(UUID().uuidString)",
                                                                    directoryHint: .isDirectory)
        let origin = SyntheticMedia.origin

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func journal(focusTurnedOn: Bool = false) -> RecordingJournal {
            RecordingJournal(startedAt: Date(timeIntervalSinceReferenceDate: 812_000_000), mode: .video, framesPerSecond: 30,
                             pixelWidth: 320, pixelHeight: 180, scale: 1, displayID: 1,
                             globalRect: CGRect(x: 0, y: 0, width: 320, height: 180), captureKind: .selection,
                             systemAudio: true, microphone: false, focusTurnedOn: focusTurnedOn)
        }

        func exists(_ url: URL) -> Bool {
            FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        }

        func creationDate(_ url: URL) throws -> Date {
            try #require(try url.resourceValues(forKeys: [.creationDateKey]).creationDate)
        }

        /// A finished 320 × 180 recording `seconds` long at `url`.
        func record(_ url: URL, seconds: Double) async throws {
            let writer = try Media.writer(url)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + seconds)
            _ = try await writer.finish(at: t(origin + seconds))
        }

        // MARK: Recovery

        @Test func anInterruptedFileIsRecoveredToTheLastFragment() async throws {
            let folder = try RecordingFolders(root: root).create(journal())
            let writer = try Media.writer(folder.movieURL, systemAudio: true)
            writer.start(at: t(origin))
            Media.feed(writer, from: origin, to: origin + 3.5, systemAudio: .system)
            // What a kill would leave: the file as written so far, its writer never finished.
            let interrupted = root.appending(path: "interrupted.mp4")
            try await Media.copyWhenSettled(folder.movieURL, to: interrupted)
            await writer.cancel()

            let recovered = root.appending(path: "recovered.mp4")
            let duration = try await RecoveryExporter.finalize(interrupted, to: recovered)
            #expect(duration >= 2.0)
            #expect(duration <= 3.5)
            #expect(try await AVURLAsset(url: recovered).load(.isPlayable))
            #expect(try Media.topLevelBoxes(recovered) == ["ftyp", "mdat", "moov"])
            let frames = try await Media.decodedFrames(recovered)
            #expect(frames.count >= 60)
            #expect(frames.first?.index == 0)
        }

        @Test func randomBytesAreUnreadable() async throws {
            let garbage = root.appending(path: "garbage.mp4")
            try Data((0..<100_000).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
            let destination = root.appending(path: "recovered.mp4")
            let error = await #expect(throws: VideoFileError.self) {
                try await RecoveryExporter.finalize(garbage, to: destination)
            }
            #expect(error.map { if case .unreadable = $0 { true } else { false } } == true)
            #expect(!exists(destination))
        }

        // MARK: The Recordings folder

        @Test func scanReportsJournalsDurationsAndAges() async throws {
            let folders = RecordingFolders(root: root)
            let recorded = try folders.create(journal(focusTurnedOn: true))
            try await record(recorded.movieURL, seconds: 1.5)
            // A journal whose recording never wrote a file.
            let unwritten = try folders.create(journal())
            // Not a recording's folder: ignored.
            try FileManager.default.createDirectory(at: root.appending(path: "Not a recording"),
                                                    withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appending(path: UUID().uuidString))

            let now = try creationDate(recorded.url).addingTimeInterval(3_600)
            let candidates = await folders.scan(now: now)
            // Oldest first.
            let names = candidates.map(\.folder.lastPathComponent)
            #expect(names == [recorded.url.lastPathComponent, unwritten.url.lastPathComponent])
            let first = try #require(candidates.first)
            #expect(first.journal == journal(focusTurnedOn: true))
            #expect(abs((first.playableDuration ?? 0) - 1.5) <= 0.001)
            #expect(abs(first.age - 3_600) < 0.001)
            let second = try #require(candidates.last)
            #expect(second.journal == journal())
            #expect(second.playableDuration == nil)
            #expect(abs(second.age - now.timeIntervalSince(try creationDate(unwritten.url))) < 0.001)
        }

        @Test func aFolderWithoutAJournalIsScannedWithNone() async throws {
            let orphan = RecordingFolder(url: root.appending(path: UUID().uuidString, directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: orphan.url, withIntermediateDirectories: true)
            try await record(orphan.movieURL, seconds: 1)
            // A journal that doesn't decode counts as none.
            let garbled = RecordingFolder(url: root.appending(path: UUID().uuidString, directoryHint: .isDirectory))
            try FileManager.default.createDirectory(at: garbled.url, withIntermediateDirectories: true)
            try Data("not a journal".utf8).write(to: garbled.journalURL)

            let candidates = await RecordingFolders(root: root).scan()
            #expect(candidates.count == 2)
            #expect(candidates.allSatisfy { $0.journal == nil })
            let orphanCandidate = try #require(candidates.first { $0.folder.lastPathComponent == orphan.url.lastPathComponent })
            #expect(abs((orphanCandidate.playableDuration ?? 0) - 1) <= 0.001)
            let garbledCandidate = try #require(candidates.first { $0.folder.lastPathComponent == garbled.url.lastPathComponent })
            #expect(garbledCandidate.playableDuration == nil)
        }

        @Test func createWritesTheJournalAndWriteReplacesIt() throws {
            let folders = RecordingFolders(root: root)
            let folder = try folders.create(journal())
            #expect(UUID(uuidString: folder.url.lastPathComponent) != nil)
            let parent = folder.url.deletingLastPathComponent().standardizedFileURL
            #expect(parent.pathComponents == root.standardizedFileURL.pathComponents)
            #expect(folder.movieURL.lastPathComponent == "recording.mp4")
            #expect(folder.gifURL.lastPathComponent == "recording.gif")
            #expect(folder.journalURL.lastPathComponent == "journal.json")
            #expect(RecordingFolder(url: folder.url) == folder)
            #expect(try JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: folder.journalURL)) == journal())

            var finishing = journal()
            finishing.state = .finishing
            try folders.write(finishing, to: folder)
            #expect(try JSONDecoder().decode(RecordingJournal.self, from: Data(contentsOf: folder.journalURL)) == finishing)
            // The default root is named, never touched here.
            let defaultRoot = RecordingFolders.defaultRoot.path(percentEncoded: false)
            #expect(defaultRoot.hasSuffix("Application Support/ClearShot/Recordings/"))
        }

        /// A folder set aside keeps its files, under the root's "Not Recovered" folder, and the scan no longer lists it.
        @Test func aFolderSetAsideKeepsItsFilesAndLeavesTheScan() async throws {
            let folders = RecordingFolders(root: root)
            let folder = try folders.create(journal())
            try await record(folder.movieURL, seconds: 1)
            let kept = try folders.create(journal())

            let moved = try folders.setAside(folder.url)
            #expect(moved == root.appending(path: "Not Recovered/\(folder.url.lastPathComponent)", directoryHint: .isDirectory))
            #expect(!exists(folder.url))
            #expect(exists(RecordingFolder(url: moved).movieURL))
            #expect(exists(RecordingFolder(url: moved).journalURL))
            #expect(await folders.scan().map(\.folder.lastPathComponent) == [kept.url.lastPathComponent])
            // Only folders directly in the root are set aside.
            let elsewhere = root.appending(path: "nested/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            #expect(throws: (any Error).self) { try folders.setAside(elsewhere) }
            #expect(exists(elsewhere))
        }

        @Test func removeDeletesOnlyFoldersInTheRoot() throws {
            let folders = RecordingFolders(root: root)
            let folder = try folders.create(journal())
            let elsewhere = root.appending(path: "nested/\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

            folders.remove(elsewhere)
            #expect(exists(elsewhere))
            folders.remove(folder.url)
            #expect(!exists(folder.url))
        }
    }
}
