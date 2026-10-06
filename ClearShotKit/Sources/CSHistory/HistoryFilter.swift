import Foundation

/// The History window's kind filter. Screenshots include opened files and clipboard images: everything that is an
/// image. A Studio Mode project has no filter of its own (Studio Mode isn't built), so only All shows one.
public enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all, screenshots, videos, gifs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .screenshots: "Screenshots"
        case .videos: "Videos"
        case .gifs: "GIFs"
        }
    }

    public func includes(_ item: HistoryItem) -> Bool {
        switch self {
        case .all: true
        case .screenshots: item.kind == .screenshot
        case .videos: item.kind == .video
        case .gifs: item.kind == .gif
        }
    }
}
