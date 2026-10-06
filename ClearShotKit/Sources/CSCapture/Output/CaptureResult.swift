import CoreGraphics
import Foundation

/// One finished screenshot, ready for the after-capture actions.
public struct CaptureResult: Sendable, Identifiable {
    public let id: UUID
    public let kind: CaptureKind
    public let image: CGImage
    /// Pixels per point of `image` (1 after "Scale Retina to 1x").
    public let scale: CGFloat
    public let displayID: UInt32
    /// The captured rect in AppKit global points.
    public let globalRect: CGRect
    public let appName: String?
    public let windowTitle: String?
    public let createdAt: Date
    /// A window shot with a transparent background.
    public let isTransparent: Bool
    /// The bundle ID of the app the capture was taken in, if known.
    public let appBundleID: String?

    public init(id: UUID = UUID(), kind: CaptureKind, image: CGImage, scale: CGFloat, displayID: UInt32, globalRect: CGRect,
                appName: String?, windowTitle: String?, createdAt: Date = Date(), isTransparent: Bool,
                appBundleID: String? = nil) {
        self.id = id
        self.kind = kind
        self.image = image
        self.scale = scale
        self.displayID = displayID
        self.globalRect = globalRect
        self.appName = appName
        self.windowTitle = windowTitle
        self.createdAt = createdAt
        self.isTransparent = isTransparent
        self.appBundleID = appBundleID
    }
}
