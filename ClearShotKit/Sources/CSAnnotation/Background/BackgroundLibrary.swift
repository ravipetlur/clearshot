import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a file couldn't join the background library.
public enum BackgroundLibraryError: Error, Equatable {
    /// ImageIO can't read the file as a picture.
    case notAnImage
}

/// The user's own background pictures: copies kept in one folder, each named by its id (`<uuid>.<ext>`), so a fill
/// refers to one by `BackgroundFill.custom(id:)`. Documents store their own copy of the picture, so removing one here
/// changes no document. The app points it at `defaultDirectory`; tests use a temporary folder.
public struct BackgroundLibrary: Sendable {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let id: UUID
        public let url: URL
    }

    /// `~/Library/Application Support/ClearShot/Backgrounds`. For the app only.
    public static let defaultDirectory: URL = .applicationSupportDirectory.appending(path: "ClearShot/Backgrounds",
                                                                                     directoryHint: .isDirectory)

    public let directory: URL

    /// How much later than the newest picture already in the library an added one is dated at least, so two adds within
    /// one tick of the clock keep their order. The file system keeps creation dates to well under this.
    static let addedDateStep: TimeInterval = 0.001

    public init(directory: URL) {
        self.directory = directory
    }

    /// Copies the picture at `source` into the library under a new id, keeping its extension in lower case (or, without
    /// one, its image type's), and making the folder if needed. A file ImageIO can't read as a picture is refused with
    /// `notAnImage` and nothing is copied. The source is left as it is. The copy is dated when it was added (its creation
    /// date), after every picture already in the library, so `entries()` lists pictures in the order they were added.
    public func add(copying source: URL) throws -> Entry {
        // `copyItem` copies a link as a link: the picture it leads to is what goes in.
        let source = source.resolvingSymlinksInPath()
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0,
              CGImageSourceCreateImageAtIndex(image, 0, nil) != nil
        else { throw BackgroundLibraryError.notAnImage }
        var fileExtension = source.pathExtension.lowercased()
        if fileExtension.isEmpty {
            let type = (CGImageSourceGetType(image) as String?).flatMap { UTType($0) }
            fileExtension = type?.preferredFilenameExtension ?? "image"
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let destination = directory.appending(path: "\(id.uuidString).\(fileExtension)")
        // `copyItem` keeps the source's creation date, which can be years old. The copy is dated now, or just after the
        // newest picture here when the clock doesn't read later than that (two adds in one tick, or a clock set back).
        let newest = datedFiles().last?.created ?? .distantPast
        let added = max(Date(), newest.addingTimeInterval(Self.addedDateStep))
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.creationDate: added], ofItemAtPath: destination.path(percentEncoded: false))
        } catch {
            // A copy that failed partway would show as a broken picture.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return Entry(id: id, url: destination)
    }

    /// The pictures in the folder, oldest first (by creation date, then id). Only regular files named `<uuid>.<ext>` count;
    /// anything else in the folder is ignored. Empty when the folder doesn't exist.
    public func entries() -> [Entry] {
        // Ids are unique in the list even if a second file with an id already used were put in the folder by hand.
        var seen = Set<UUID>()
        return files().filter { seen.insert($0.id).inserted }
    }

    /// The file of the picture with `id`, whatever its extension, or nil when there is none.
    public func url(for id: UUID) -> URL? {
        files().first { $0.id == id }?.url
    }

    /// Deletes the picture with `id`. No error when it is already gone.
    public func remove(_ id: UUID) throws {
        for file in files() where file.id == id {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch CocoaError.fileNoSuchFile {
                // Removed by someone else in the meantime.
            }
        }
    }

    /// Every regular file named `<uuid>.<ext>`, oldest first (by creation date, then id).
    private func files() -> [Entry] {
        datedFiles().map(\.entry)
    }

    /// `files()` with each one's creation date.
    private func datedFiles() -> [(entry: Entry, created: Date)] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey]
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles])) ?? []
        let dated = contents.compactMap { url -> (entry: Entry, created: Date)? in
            let name = url.lastPathComponent
            guard let id = Self.id(fromFileName: name),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { return nil }
            // Built from the folder the library was given, so an entry's URL is the same whichever way it was found.
            return (Entry(id: id, url: directory.appending(path: name)), values.creationDate ?? .distantPast)
        }
        return dated.sorted { ($0.created, $0.entry.id.uuidString) < ($1.created, $1.entry.id.uuidString) }
    }

    /// The id a library file name `<uuid>.<ext>` holds, or nil for any other name.
    private static func id(fromFileName name: String) -> UUID? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return UUID(uuidString: String(parts[0]))
    }
}
