import CoreGraphics
import CSCore
import Darwin
import Foundation

/// What marks a file as a screenshot ClearShot captured: the kind of capture and the captured rect in AppKit global
/// points (origin at the main display's bottom-left). Only a captured screenshot has one
/// (`HistoryItem.screenCaptureTag`); an opened or pasted image, a video and a GIF have none.
public struct ScreenCaptureTag: Sendable, Equatable {
    public let kind: CaptureKind
    public let globalRect: CGRect

    public init(kind: CaptureKind, globalRect: CGRect) {
        self.kind = kind
        self.globalRect = globalRect
    }
}

/// Spotlight attributes macOS's own screenshots carry, so Finder and Spotlight treat ours the same.
public enum ScreenCaptureMetadata {
    static let isScreenCaptureKey = "com.apple.metadata:kMDItemIsScreenCapture"
    static let typeKey = "com.apple.metadata:kMDItemScreenCaptureType"
    static let rectKey = "com.apple.metadata:kMDItemScreenCaptureGlobalRect"

    /// Writes the three attributes. Nothing throws: a file that can't take them is still a good file. False when any
    /// write failed, which `logger` records once ("Couldn't mark <name> as a screenshot: <reason>").
    @discardableResult
    public static func apply(_ tag: ScreenCaptureTag, to url: URL, logger: AppLogger = Log.capture) -> Bool {
        let rect = [tag.globalRect.minX, tag.globalRect.minY, tag.globalRect.width, tag.globalRect.height].map(Double.init)
        let failures = [
            write(true, key: isScreenCaptureKey, to: url),
            write(tag.kind.rawValue, key: typeKey, to: url),
            write(rect, key: rectKey, to: url),
        ].compactMap { $0 }
        guard let failure = failures.first else { return true }
        logger.error("Couldn't mark \(url.lastPathComponent) as a screenshot: \(failure)")
        return false
    }

    public static func isScreenCapture(_ url: URL) -> Bool {
        (read(key: isScreenCaptureKey, from: url) as? Bool) ?? false
    }

    public static func captureType(_ url: URL) -> String? {
        read(key: typeKey, from: url) as? String
    }

    /// The rect as written, `[x, y, width, height]`; nil when the file has none.
    public static func globalRect(_ url: URL) -> CGRect? {
        guard let values = read(key: rectKey, from: url) as? [Double], values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    /// Writes one attribute: nil when it worked, else why it didn't.
    private static func write(_ value: Any, key: String, to url: URL) -> String? {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) else {
            return "\(key) couldn't be encoded"
        }
        return url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return "its path can't be represented" }
            // errno is read straight after the call that set it.
            let code = data.withUnsafeBytes { bytes -> Int32 in
                setxattr(path, key, bytes.baseAddress, data.count, 0, 0) == 0 ? 0 : errno
            }
            return code == 0 ? nil : String(cString: strerror(code))
        }
    }

    private static func read(key: String, from url: URL) -> Any? {
        url.withUnsafeFileSystemRepresentation { path -> Any? in
            guard let path else { return nil }
            let length = getxattr(path, key, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var buffer = Data(count: length)
            let read = buffer.withUnsafeMutableBytes { getxattr(path, key, $0.baseAddress, length, 0, 0) }
            guard read == length else { return nil }
            return try? PropertyListSerialization.propertyList(from: buffer, format: nil)
        }
    }
}
