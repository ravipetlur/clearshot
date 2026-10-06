import CoreGraphics
import Foundation
import ImageIO

/// The pictures macOS ships as wallpapers: the still pictures directly in `/System/Library/Desktop Pictures`. A fill
/// refers to one by its file name (`BackgroundFill.systemWallpaper(fileName:)`).
public enum SystemWallpapers {
    public static let directory: URL = URL(filePath: "/System/Library/Desktop Pictures", directoryHint: .isDirectory)

    /// The extensions of the pictures listed, in lower case.
    private static let pictureExtensions: Set<String> = ["heic", "jpg", "jpeg", "png"]

    /// The names of the regular files directly in `directory` with a picture extension (HEIC, JPEG or PNG, in any case),
    /// as Finder sorts them. Folders, bundles, `.madesktop` files and dot files are skipped. Empty when the folder doesn't
    /// exist.
    public static func fileNames(in directory: URL = directory) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: [.isRegularFileKey],
                                                                     options: [.skipsHiddenFiles])) ?? []
        return contents.filter { url in
            !url.lastPathComponent.hasPrefix(".") && pictureExtensions.contains(url.pathExtension.lowercased())
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        .map(\.lastPathComponent)
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The file of the wallpaper named `fileName` in `directory`, or nil unless it is one `fileNames` lists. The name comes
    /// from a document or preset that may not be ours, so one that is empty, `.` or `..`, or holds `/` or NUL is refused
    /// before the folder is read.
    public static func url(for fileName: String, in directory: URL = directory) -> URL? {
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("/"), !fileName.contains("\0"),
              fileNames(in: directory).contains(fileName)
        else { return nil }
        return directory.appending(path: fileName)
    }
}

/// A small copy of a picture file for a tile in the background panel. Decodes the file, so the app calls it off the main
/// actor.
public enum PictureThumbnail {
    /// The file's first picture, upright and at most `maxPixel` on its longest side; nil when it can't be read. A dynamic
    /// wallpaper's first picture stands for it.
    public static func make(at url: URL, maxPixel: Int = 160) -> CGImage? {
        guard maxPixel > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
