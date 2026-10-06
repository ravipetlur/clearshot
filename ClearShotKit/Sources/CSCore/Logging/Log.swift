import Foundation
import os

/// Logs to the unified log (Console.app, subsystem: the app's bundle identifier) and, for info and above,
/// to ~/Library/Logs/ClearShot/clearshot.log.
public struct AppLogger: Sendable {
    public let category: String
    private let logger: Logger
    private let sink: FileLogSink?

    public init(category: String, sink: FileLogSink? = .shared) {
        self.category = category
        self.logger = Logger(subsystem: Log.subsystem, category: category)
        self.sink = sink
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        sink?.append(level: .info, category: category, message: message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        sink?.append(level: .warning, category: category, message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        sink?.append(level: .error, category: category, message: message)
    }
}

public enum Log {
    public static let subsystem = CSCore.bundleIdentifier
    public static let app = AppLogger(category: "app")
    public static let hotkeys = AppLogger(category: "hotkeys")
    public static let permissions = AppLogger(category: "permissions")
    public static let capture = AppLogger(category: "capture")
    public static let recording = AppLogger(category: "recording")
    public static let annotate = AppLogger(category: "annotate")
    public static let history = AppLogger(category: "history")
    public static let api = AppLogger(category: "api")
}
