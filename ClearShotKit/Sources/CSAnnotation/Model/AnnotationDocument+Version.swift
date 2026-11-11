import Foundation

/// Which version a document is written as, and what reading an older one changes.
///
/// A document is written at the lowest version that holds everything in it (`requiredVersion`): one that uses nothing
/// newer than version 2 is still version 2, which every released build reads; one that uses anything in
/// `formatFeatures` is the version that feature came with, so an older build refuses it (`DocumentError.newerVersion`)
/// instead of failing on an object kind it doesn't know, or dropping a fill or an opacity and drawing the object wrong.
extension AnnotationDocument {
    /// The version a document using nothing in `formatFeatures` is written as. Every released build reads it (they all
    /// wrote version 2), and a document without a background or window-shot flag is the same in it as in version 1.
    public static let baseVersion = 2

    /// Something a version of the format added to objects, which an older build would refuse, drop or draw wrong.
    public struct FormatFeature: Sendable {
        /// What it is, for messages and tests.
        public let name: String
        /// The first version that holds it.
        public let version: Int
        /// Whether `object` uses it.
        public let isUsed: @Sendable (AnnotationObject) -> Bool
    }

    /// Everything a version after `baseVersion` added, in one place. A feature that adds data a version-2 build can't keep
    /// adds a line here (for a redaction's, in `requiredVersion(of:)`), and bumps `currentVersion` if it is the first of a
    /// new version.
    public static let formatFeatures: [FormatFeature] = [
        FormatFeature(name: "image opacity", version: 3) { object in
            if case .image(let image) = object.kind { image.opacity != 1 } else { false }
        },
        FormatFeature(name: "shape fill", version: 3) { $0.style.hasFill },
        FormatFeature(name: "hand-drawn shape", version: 3) { $0.style.handDrawn },
        FormatFeature(name: "hand-drawn text", version: 3) { object in
            if case .text(let text) = object.kind { text.handDrawn } else { false }
        },
        // A curved arrow was always bent by its control point; another style with one is new (and older builds draw it
        // straight).
        FormatFeature(name: "bent arrow", version: 3) { object in
            if case .arrow(let arrow) = object.kind { arrow.control != nil && arrow.style != .curved } else { false }
        },
        FormatFeature(name: "ruler", version: 3) { object in
            if case .ruler = object.kind { true } else { false }
        },
        FormatFeature(name: "magnifier", version: 3) { object in
            if case .magnifier = object.kind { true } else { false }
        },
        FormatFeature(name: "redaction", version: 3) { object in
            if case .redact(let redact) = object.kind { requiredVersion(of: redact) > baseVersion } else { false }
        },
    ]

    /// The version a redaction needs. The switch names every style, so a new style doesn't compile until it says which
    /// version it needs (Erase: 3). A text-only redaction needs 3 too: an older build would cover its whole rect, which
    /// hides as much but isn't what was drawn. `isSecretsMask` needs none: an older build reads it as an ordinary
    /// redaction, which hides the same pixels.
    public static func requiredVersion(of redact: RedactObject) -> Int {
        let style = switch redact.style {
        case .pixelate, .secureBlur, .smoothBlur, .blackOut: baseVersion
        }
        return redact.textOnly ? max(style, 3) : style
    }

    /// The lowest version that holds everything in the document: `baseVersion`, or the newest version of a feature it
    /// uses.
    public var requiredVersion: Int {
        objects.reduce(Self.baseVersion) { version, object in
            Self.formatFeatures.reduce(version) { $1.version > $0 && $1.isUsed(object) ? $1.version : $0 }
        }
    }

    /// The features in `formatFeatures` the document uses, by name.
    public var formatFeaturesUsed: [String] {
        Self.formatFeatures.filter { feature in objects.contains(where: feature.isUsed) }.map(\.name)
    }

    /// Whether a build that reads up to `newest` opens a file of `version`: what `DocumentPackage.readDocument` asks with
    /// this build's `currentVersion`.
    public static func canRead(version: Int, newest: Int = currentVersion) -> Bool {
        version <= newest
    }

    /// `objects` read from a file of `version`, as they mean today.
    ///
    /// Before version 3 only a curved arrow was bent by its control point; switching it to another style kept the point,
    /// unseen. Every style is bent by it now, so an older file's non-curved arrow loses it and stays straight.
    static func migrated(_ objects: [AnnotationObject], from version: Int) -> [AnnotationObject] {
        guard version < 3 else { return objects }
        return objects.map { object in
            guard case .arrow(var arrow) = object.kind, arrow.style != .curved, arrow.control != nil else { return object }
            arrow.control = nil
            var copy = object
            copy.kind = .arrow(arrow)
            return copy
        }
    }
}
