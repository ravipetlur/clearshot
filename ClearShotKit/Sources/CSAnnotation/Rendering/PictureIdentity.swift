import CoreGraphics
import CSHistory
import Foundation
import ImageIO

/// What decides which pixels a document's picture has, and where each one lies in the base: the base's size, the image
/// operations, the canvas and its fill, and the redactions. This is `AnnotationDocument.pictureOnly` without what doesn't
/// matter to where a finding's rectangle is.
///
/// The secrets check keeps one beside what it found, to tell whether a change to the capture has moved the picture the
/// findings lie on. Annotations are drawn over the picture, and a background around it, so adding a label or a background
/// in Annotate rewrites the working copy and leaves the findings where they are; a turn, a crop, a resize or a redaction
/// doesn't. Left out too: the pixel scale (it only sizes the Pixelate blocks), the window flag, and the name the base is
/// stored under.
public struct PictureIdentity: Equatable, Sendable {
    public let baseSize: CGSize
    public let imageOps: [ImageOp]
    public let canvasRect: CGRect?
    public let canvasFill: CanvasFill
    /// The redactions, in the document's order.
    public let redactions: [AnnotationObject]

    public init(baseSize: CGSize, imageOps: [ImageOp], canvasRect: CGRect?, canvasFill: CanvasFill, redactions: [AnnotationObject]) {
        self.baseSize = baseSize
        self.imageOps = imageOps
        self.canvasRect = canvasRect
        self.canvasFill = canvasFill
        self.redactions = redactions
    }

    /// The picture of a capture nothing has been done to, `size` pixels across: a document over it with no operations, no
    /// crop and no redactions. A capture never annotated is scanned as its working copy, which is exactly that picture once
    /// Annotate opens a document over it.
    public static func plain(size: CGSize) -> PictureIdentity {
        PictureIdentity(baseSize: size, imageOps: [], canvasRect: nil, canvasFill: .auto, redactions: [])
    }
}

extension PictureIdentity {
    /// Whether findings read from the picture `known` still lie on the document, whose picture is `current` now. They do only if
    /// nothing has said otherwise (`stillCurrent`, the coordinator's own last verdict) and it is the same picture. With no
    /// picture known (`known` nil: the scan hasn't finished, or its findings were given up) nothing stands.
    ///
    /// Undo Mask asks this with the document's identity just before it takes the masks out: a flip, a turn (a half turn too, which
    /// leaves the size alone), a crop, a resize or a redaction made in the meantime moves the findings' rectangles off their text,
    /// and a picture check still on its way hasn't said so yet.
    public static func findingsStand(readFrom known: PictureIdentity?, nowOn current: PictureIdentity, stillCurrent: Bool) -> Bool {
        stillCurrent && known == current
    }

    /// What a badge that says "Masked" does when the picture check reads the document after a change that isn't Mask All's or
    /// Undo Mask's (Done in Annotate), and the document isn't the picture the badge was holding (`known`: the picture with the
    /// masks `maskIDs` in it, as Mask All left it, or nil when the findings had already been given up).
    public enum MaskedBadgeChange: Equatable, Sendable {
        /// Some mask is still in the document (moved, restyled or not, whatever else changed), or there are none to look for: the
        /// badge still says "Masked", and what it knows of the picture is out of date.
        case masksRemain
        /// Every mask is gone and the picture is otherwise the one that was scanned (a label or a background doesn't count): the
        /// badge goes back to the findings it had, as Undo Mask would put it.
        case findingsBack
        /// Every mask is gone, and the picture has changed besides, or the findings were already out of date or given up: the
        /// findings aren't where the text is any more, so the capture is scanned again.
        case rescan
    }

    /// The change to a masked badge for the document that is `current` now. Only when **none** of `maskIDs` is among its
    /// redactions is the badge no longer true, and then the findings come back only if the document without the masks is exactly the
    /// picture they were read from: `known` less the masks (what Mask All's picture was before them), `current` the same
    /// picture (`findingsStand`).
    public static func maskedBadgeChange(maskIDs: [UUID], readFrom known: PictureIdentity?, nowOn current: PictureIdentity,
                                         stillCurrent: Bool) -> MaskedBadgeChange {
        let masks = Set(maskIDs)
        guard !masks.isEmpty, !current.redactions.contains(where: { masks.contains($0.id) }) else { return .masksRemain }
        guard let known else { return .rescan }
        let scanned = PictureIdentity(baseSize: known.baseSize, imageOps: known.imageOps, canvasRect: known.canvasRect,
                                      canvasFill: known.canvasFill, redactions: known.redactions.filter { !masks.contains($0.id) })
        return findingsStand(readFrom: scanned, nowOn: current, stillCurrent: stillCurrent) ? .findingsBack : .rescan
    }
}

extension AnnotationDocument {
    /// The identity of the document's picture (`PictureIdentity`).
    public var pictureIdentity: PictureIdentity {
        PictureIdentity(baseSize: baseSize, imageOps: imageOps, canvasRect: canvasRect, canvasFill: canvasFill,
                        redactions: pictureOnly.objects)
    }
}

extension AnnotationStorage {
    /// The identity of the picture of the item's saved document, read from `document.json` and the base image's header alone:
    /// no image is decoded, nothing is written. The base size is the base image's own, as `open` takes it over the document's
    /// ("the base is ours"), so this and the document `open` returns agree. Nil when the item has no document, its document
    /// can't be read (`DocumentPackage.readDocument`) or isn't well formed, or its base image is gone, so a caller that
    /// compares it with a known identity takes "can't tell" as "changed".
    public static func pictureIdentity(of item: HistoryItem, root: URL) -> PictureIdentity? {
        guard item.hasDocument == true else { return nil }
        let folder = item.folder(in: root)
        guard var document = try? DocumentPackage.readDocument(from: folder), let url = document.base.url(in: folder),
              let size = pixelSize(ofImageAt: url) else { return nil }
        document.baseSize = size
        guard document.isWellFormed else { return nil }
        return document.pictureIdentity
    }

    /// The size in pixels of the first image in the file, from its header; nil if it isn't one.
    private static func pixelSize(ofImageAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
