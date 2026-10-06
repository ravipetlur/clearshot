import Foundation
import UniformTypeIdentifiers

/// Checks a URL command's `filepath` on the disk (`validate`), which reads the file's kind and type (by its extension)
/// only, and reads an image file for a command that opens one (`read`). Nothing ever writes the file.
public enum APIFiles {
    /// The file a command may use, as a file URL.
    ///
    /// - `~` and `~/…` expand against `home`; any other path must be absolute.
    /// - It must exist and be a regular file, or, for `.imageOrProject`, a folder whose extension is `projectExtension`
    ///   (the app passes `DocumentPackage.fileExtension`). A link counts as the regular file it points to, never as a
    ///   folder: a link named like a project can't open just any folder in Annotate.
    /// - It must be readable, and its extension's type an image (or a movie, for `.imageOrMovie`).
    ///
    /// The file can change after this check: a command that opens it as an image reads it with `read`, which checks it
    /// again on the descriptor it reads.
    public static func validate(_ path: String, as kind: APIFileKind, projectExtension: String,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) throws(APIError) -> URL {
        let homePath = trimmingTrailingSlashes(home.path(percentEncoded: false))
        let given = if path == "~" {
            homePath
        } else if path.hasPrefix("~/") {
            homePath + path.dropFirst()
        } else {
            path
        }
        guard given.hasPrefix("/") else { throw .relativePath(path) }
        // Without trailing slashes, which would make `lstat` follow a link.
        let expanded = trimmingTrailingSlashes(given)

        var info = stat()
        guard !expanded.contains("\0"), lstat(expanded, &info) == 0 else {
            throw .fileNotFound(abbreviating(expanded, home: homePath))
        }
        let isLink = info.st_mode & S_IFMT == S_IFLNK
        if isLink, stat(expanded, &info) != 0 {
            throw .fileNotFound(abbreviating(expanded, home: homePath))
        }
        let url = URL(filePath: expanded)
        let name = url.lastPathComponent
        let fileType = info.st_mode & S_IFMT
        let isProject = !isLink && fileType == S_IFDIR && kind == .imageOrProject
            && url.pathExtension.lowercased() == projectExtension.lowercased()
        guard fileType == S_IFREG || isProject else { throw .notAFile(name) }
        guard FileManager.default.isReadableFile(atPath: expanded) else { throw .unreadable(name) }
        if isProject {
            return URL(filePath: expanded, directoryHint: .isDirectory)
        }

        let accepted: [UTType] = kind == .imageOrMovie ? [.image, .movie] : [.image]
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()),
              accepted.contains(where: type.conforms(to:))
        else { throw .wrongFileType(name, expected: kind) }
        return URL(filePath: expanded, directoryHint: .notDirectory)
    }

    /// The most bytes `read` takes: 1 GiB, far above any picture ClearShot decodes (`ImageOps.maximumLoadedSide`).
    public static let readLimit = 1 << 30

    /// The bytes of a checked file (`validate`) that a command opens as an image (pin, open-annotate, capture-text),
    /// read through one descriptor, so what is read is the file as it is checked then, whatever replaced it since
    /// `validate`:
    /// - it is opened without waiting (`O_NONBLOCK`), so a FIFO swapped in can't hold the open up until a writer comes;
    /// - the open descriptor must be a regular file (`fstat`): a FIFO, a device, a socket or a folder, or a link to
    ///   one, is refused as not a file;
    /// - a file bigger than `limit` bytes is refused rather than read into memory.
    ///
    /// Reading may still wait: for a file kept only in iCloud, which downloads, or one on a stalled network volume. The
    /// app calls it off the main actor.
    public static func read(_ file: URL, limit: Int = readLimit,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws(APIError) -> Data {
        let path = file.path(percentEncoded: false)
        let name = file.lastPathComponent
        let descriptor = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let missing = errno == ENOENT || errno == ENOTDIR
            let homePath = trimmingTrailingSlashes(home.path(percentEncoded: false))
            throw missing ? .fileNotFound(abbreviating(path, home: homePath)) : .unreadable(name)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(name) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notAFile(name) }
        guard info.st_size <= limit else { throw .tooLarge(name) }
        // A regular file: reads block as usual from here on.
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw .unreadable(name) }

        var data = Data(capacity: Int(info.st_size))
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = chunk.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { return data }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw .unreadable(name)
            }
            // It may have grown since `fstat`.
            guard data.count + count <= limit else { throw .tooLarge(name) }
            data.append(contentsOf: chunk[..<count])
        }
    }

    /// `path` with `home` shown as `~`, as an error message shows it.
    private static func abbreviating(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }
}
