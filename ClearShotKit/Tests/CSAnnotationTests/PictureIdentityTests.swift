import CoreGraphics
import CSHistory
import Foundation
import Testing
@testable import CSAnnotation

/// What the secrets check treats as "the picture": a finding's rectangle lies on the picture of a document (its base with the
/// image operations, the canvas and the redactions), and goes stale only when that changes. Annotations and the background
/// are drawn over or around it, so adding a label or a background in Annotate leaves the findings where they are.
struct PictureIdentityTests {
    private func base() -> CGImage { TestBitmaps.solid(120, 80, TestBitmaps.white) }

    private func document() -> (AnnotationDocument, ImageStore) {
        TestBitmaps.document(base: base())
    }

    private let red = RGBAColor(red: 1, green: 0, blue: 0)

    private func label() -> AnnotationObject {
        AnnotationObject(kind: .filledRectangle(CGRect(x: 40, y: 15, width: 40, height: 30)), style: ObjectStyle(color: red, lineWidth: 1, shadow: false))
    }

    private func background() -> DocumentBackground {
        DocumentBackground(style: BackgroundStyle(fill: .color(RGBAColor(red: 0.6, green: 0.6, blue: 0.6)), padding: 20, inset: 0,
                                                  insetColor: .color(RGBAColor(red: 1, green: 1, blue: 1)), shadow: 0, corners: 0,
                                                  autoBalance: false, alignment: .center, ratio: .auto))
    }

    private let mask = AnnotationObject.pixelateMask(rect: CGRect(x: 10, y: 10, width: 40, height: 12), intensity: 5)

    // MARK: What it is made of

    @Test func aDocumentNothingHasBeenDoneToIsPlain() {
        let (document, _) = document()
        #expect(document.pictureIdentity == .plain(size: CGSize(width: 120, height: 80)))
        #expect(PictureIdentity.plain(size: CGSize(width: 120, height: 80)) != .plain(size: CGSize(width: 80, height: 120)))
    }

    @Test func annotationsAndABackgroundDontChangeIt() {
        var (document, _) = document()
        let plain = document.pictureIdentity
        document.objects = [label(), AnnotationObject(kind: .rectangle(CGRect(x: 1, y: 1, width: 9, height: 9)),
                                                      style: ObjectStyle(color: red, lineWidth: 2, shadow: true))]
        #expect(document.pictureIdentity == plain)
        document.background = background()
        #expect(document.pictureIdentity == plain)
    }

    @Test func theScaleTheWindowFlagAndTheNameOfTheBaseDontChangeIt() {
        var (document, _) = document()
        let plain = document.pictureIdentity
        document.pixelScale = 2
        document.isWindowShot = true
        document.base = AnnotationStorage.historyBase
        #expect(document.pictureIdentity == plain)
    }

    @Test func imageOperationsChangeIt() {
        var (document, _) = document()
        let plain = document.pictureIdentity
        for op in [ImageOp.rotateLeft, .rotateRight, .flipHorizontal, .flipVertical, .resize(width: 60, height: 40)] {
            document.imageOps = [op]
            #expect(document.pictureIdentity != plain, "\(op)")
        }
        // The same operations in another order are another picture.
        document.imageOps = [.rotateRight, .flipHorizontal]
        let first = document.pictureIdentity
        document.imageOps = [.flipHorizontal, .rotateRight]
        #expect(document.pictureIdentity != first)
    }

    @Test func theCanvasAndItsFillChangeIt() {
        var (document, _) = document()
        let plain = document.pictureIdentity
        document.canvasRect = CGRect(x: 10, y: 5, width: 80, height: 60)
        let cropped = document.pictureIdentity
        #expect(cropped != plain)
        document.canvasRect = CGRect(x: 10, y: 6, width: 80, height: 60)
        #expect(document.pictureIdentity != cropped)
        document.canvasRect = CGRect(x: -20, y: -10, width: 170, height: 110)
        let expanded = document.pictureIdentity
        document.canvasFill = .color(red)
        #expect(document.pictureIdentity != expanded)
        document.canvasFill = .transparent
        #expect(document.pictureIdentity != expanded)
    }

    @Test func theSizeOfTheBaseChangesIt() {
        var (document, _) = document()
        let plain = document.pictureIdentity
        document.baseSize = CGSize(width: 121, height: 80)
        #expect(document.pictureIdentity != plain)
    }

    @Test func redactionsChangeItBecauseTheyChangeThePixels() {
        var (document, _) = document()
        let plain = document.pictureIdentity
        document.objects = [mask]
        let masked = document.pictureIdentity
        #expect(masked != plain)
        // Moved, restyled or taken out: each is another picture.
        var moved = mask
        moved.kind = .redact(RedactObject(rect: CGRect(x: 11, y: 10, width: 40, height: 12), style: .pixelate, intensity: 5))
        document.objects = [moved]
        #expect(document.pictureIdentity != masked)
        document.objects = [AnnotationObject.pixelateMask(rect: mask.redactRect, intensity: 6, id: mask.id)]
        #expect(document.pictureIdentity != masked)
        document.objects = []
        #expect(document.pictureIdentity == plain)
        // With an annotation beside them they are the same picture.
        document.objects = [label(), mask]
        #expect(document.pictureIdentity == masked)
    }

    // MARK: Whether findings still stand

    @Test func findingsStandOnlyOnThePictureTheyWereReadFromAndOnlyIfNothingHasSaidOtherwise() {
        let plain = PictureIdentity.plain(size: CGSize(width: 120, height: 80))
        let other = PictureIdentity.plain(size: CGSize(width: 80, height: 120))
        #expect(PictureIdentity.findingsStand(readFrom: plain, nowOn: plain, stillCurrent: true))
        // The same picture, but the coordinator has already marked them out of date.
        #expect(!PictureIdentity.findingsStand(readFrom: plain, nowOn: plain, stillCurrent: false))
        // Another picture, whatever the verdict.
        #expect(!PictureIdentity.findingsStand(readFrom: plain, nowOn: other, stillCurrent: true))
        #expect(!PictureIdentity.findingsStand(readFrom: plain, nowOn: other, stillCurrent: false))
        // No picture known (a scan that hasn't finished, or one given up): nothing stands.
        #expect(!PictureIdentity.findingsStand(readFrom: nil, nowOn: plain, stillCurrent: true))
    }

    @Test func undoMaskKeepsTheFindingsOnlyWhenTheDocumentIsStillTheMaskedOneBesidesAnnotations() {
        // Mask All left the document with its masks; the identity then is what the coordinator keeps. Undo Mask asks about the
        // document as it is just before the masks come out.
        var (masked, _) = document()
        masked.objects = [mask]
        let known = masked.pictureIdentity
        func stands(_ change: (inout AnnotationDocument) -> Void) -> Bool {
            var now = masked
            change(&now)
            return PictureIdentity.findingsStand(readFrom: known, nowOn: now.pictureIdentity, stillCurrent: true)
        }
        #expect(stands { _ in })
        // Annotations and a background don't move the picture.
        #expect(stands { $0.objects.append(label()) })
        #expect(stands { $0.background = background() })
        // A turn, a flip (even a turn by 180 degrees), a crop, a resize, a fill: the findings are on another picture.
        #expect(!stands { $0.imageOps = [.flipHorizontal] })
        #expect(!stands { $0.imageOps = [.rotateRight, .rotateRight] })
        #expect(!stands { $0.canvasRect = CGRect(x: 5, y: 5, width: 100, height: 60) })
        #expect(!stands { $0.imageOps = [.resize(width: 60, height: 40)] })
        // A redaction added beside the masks, or one of the masks moved or taken out, is a change to the pixels.
        #expect(!stands { $0.objects.append(AnnotationObject.pixelateMask(rect: CGRect(x: 60, y: 40, width: 20, height: 10), intensity: 3)) })
        #expect(!stands { $0.objects = [] })
        var moved = mask
        moved.kind = .redact(RedactObject(rect: CGRect(x: 12, y: 10, width: 40, height: 12), style: .pixelate, intensity: 5))
        #expect(!stands { $0.objects = [moved] })
    }

    // MARK: A masked badge when the picture changes

    /// What a masked badge does when the picture check reads the document after a change that isn't Mask All's or Undo Mask's:
    /// `known` is what Mask All left (the picture with the masks `ids` in it), and `change` is what the person did in Annotate to
    /// the document that had them. A pre-existing redaction is in the picture before the masks and after them.
    private func maskedBadgeChange(ids: [UUID]? = nil, known: PictureIdentity? = nil, stillCurrent: Bool = true,
                                   change: (inout AnnotationDocument) -> Void) -> PictureIdentity.MaskedBadgeChange {
        var (document, _) = document()
        document.objects = [earlier, maskA, maskB]
        let left = document.pictureIdentity
        change(&document)
        return PictureIdentity.maskedBadgeChange(maskIDs: ids ?? [maskA.id, maskB.id], readFrom: known ?? left,
                                                 nowOn: document.pictureIdentity, stillCurrent: stillCurrent)
    }

    private let earlier = AnnotationObject.pixelateMask(rect: CGRect(x: 70, y: 50, width: 30, height: 10), intensity: 4)
    private let maskA = AnnotationObject.pixelateMask(rect: CGRect(x: 10, y: 10, width: 40, height: 12), intensity: 5)
    private let maskB = AnnotationObject.pixelateMask(rect: CGRect(x: 10, y: 30, width: 50, height: 12), intensity: 5)

    @Test func aMaskedBadgeGoesBackToItsFindingsWhenEveryMaskIsDeletedAndNothingElseOfThePictureChanged() {
        let removed: (inout AnnotationDocument) -> Void = { $0.objects = [earlier] }
        #expect(maskedBadgeChange(change: removed) == .findingsBack)
        // What isn't the picture doesn't matter: a label, a background.
        #expect(maskedBadgeChange { $0.objects = [earlier, label()] } == .findingsBack)
        #expect(maskedBadgeChange {
            $0.objects = [earlier]
            $0.background = background()
        } == .findingsBack)
        // The masks gone while a label was deleted and another drawn.
        #expect(maskedBadgeChange { $0.objects = [label(), earlier, label()] } == .findingsBack)
    }

    @Test func aMaskedBadgeScansAgainWhenEveryMaskIsDeletedAndThePictureChangedBesides() {
        // A redaction that was there before the masks, taken out or moved, or another one drawn by hand: other pixels.
        #expect(maskedBadgeChange { $0.objects = [] } == .rescan)
        var moved = earlier
        moved.kind = .redact(RedactObject(rect: CGRect(x: 72, y: 50, width: 30, height: 10), style: .pixelate, intensity: 4))
        #expect(maskedBadgeChange { $0.objects = [moved] } == .rescan)
        #expect(maskedBadgeChange {
            $0.objects = [earlier, AnnotationObject.pixelateMask(rect: CGRect(x: 1, y: 1, width: 9, height: 9), intensity: 3)]
        } == .rescan)
        // A turn, a flip, a crop or a resize in the same session.
        #expect(maskedBadgeChange { $0.objects = [earlier]; $0.imageOps = [.rotateRight] } == .rescan)
        #expect(maskedBadgeChange { $0.objects = [earlier]; $0.imageOps = [.flipHorizontal] } == .rescan)
        #expect(maskedBadgeChange { $0.objects = [earlier]; $0.imageOps = [.rotateRight, .rotateRight] } == .rescan)
        #expect(maskedBadgeChange { $0.objects = [earlier]; $0.canvasRect = CGRect(x: 5, y: 5, width: 100, height: 60) } == .rescan)
        #expect(maskedBadgeChange { $0.objects = [earlier]; $0.imageOps = [.resize(width: 60, height: 40)] } == .rescan)
    }

    @Test func aMaskedBadgeScansAgainWhenTheFindingsWereAlreadyOutOfDateOrNoPictureIsKnown() {
        // Every mask gone, the picture the scanned one, but the coordinator had already marked the findings out of date (a crop in
        // an earlier session) or has given them up (no picture known): nothing stands to come back.
        #expect(maskedBadgeChange(stillCurrent: false) { $0.objects = [earlier] } == .rescan)
        var (document, _) = document()
        document.objects = [earlier]
        #expect(PictureIdentity.maskedBadgeChange(maskIDs: [maskA.id, maskB.id], readFrom: nil, nowOn: document.pictureIdentity,
                                                  stillCurrent: true) == .rescan)
        #expect(PictureIdentity.maskedBadgeChange(maskIDs: [maskA.id, maskB.id], readFrom: nil, nowOn: document.pictureIdentity,
                                                  stillCurrent: false) == .rescan)
    }

    @Test func aMaskedBadgeStaysMaskedWhileAnyMaskIsLeft() {
        // One of two deleted, the picture changed or not, moved or restyled: a mask is still there.
        #expect(maskedBadgeChange { $0.objects = [earlier, maskB] } == .masksRemain)
        #expect(maskedBadgeChange { $0.objects = [earlier, maskA] } == .masksRemain)
        #expect(maskedBadgeChange { $0.objects = [earlier, maskA]; $0.imageOps = [.flipHorizontal] } == .masksRemain)
        var moved = maskA
        moved.kind = .redact(RedactObject(rect: CGRect(x: 12, y: 10, width: 40, height: 12), style: .pixelate, intensity: 5))
        #expect(maskedBadgeChange { $0.objects = [earlier, moved, maskB] } == .masksRemain)
        // A turn with the masks kept, with or without the findings known.
        #expect(maskedBadgeChange { $0.imageOps = [.rotateLeft] } == .masksRemain)
        var (document, _) = document()
        document.objects = [earlier, maskA]
        #expect(PictureIdentity.maskedBadgeChange(maskIDs: [maskA.id, maskB.id], readFrom: nil, nowOn: document.pictureIdentity,
                                                  stillCurrent: false) == .masksRemain)
    }

    @Test func aMaskedBadgeWithNoMasksToLookForSaysNothingOfThem() {
        // No mask IDs (Mask All keeps them, so this isn't reached): nothing was deleted, so nothing changes the badge.
        #expect(maskedBadgeChange(ids: []) { $0.objects = [earlier] } == .masksRemain)
    }

    // MARK: A capture nothing has been done to behaves as it did

    @Test func anObjectFreeBackgroundFreeDocumentIsItsOwnPicture() throws {
        // The scan of a never-annotated capture reads the working copy, and Mask All maps through a new document over it. The
        // picture-only document of that is the document itself, with the same mapping to the base, so nothing changes for it.
        var (document, images) = document()
        let documents: [(String, (inout AnnotationDocument) -> Void)] = [
            ("plain", { _ in }),
            ("2x", { $0.pixelScale = 2 }),
            ("turned", { $0.imageOps = [.rotateRight] }),
            ("flipped", { $0.imageOps = [.flipHorizontal] }),
            ("resized", { $0.imageOps = [.resize(width: 60, height: 40)] }),
            ("cropped", { $0.canvasRect = CGRect(x: 10, y: 5, width: 80, height: 60) }),
            ("expanded", { $0.canvasRect = CGRect(x: -20, y: -10, width: 170, height: 110); $0.canvasFill = .transparent }),
            ("part pixels", { $0.canvasRect = CGRect(x: 10.4, y: 5.6, width: 79.7, height: 59.9) }),
            ("everything", { $0.imageOps = [.rotateLeft, .resize(width: 70, height: 100)]; $0.canvasRect = CGRect(x: -4, y: 3, width: 82, height: 96) }),
        ]
        let original = document
        for (name, change) in documents {
            document = original
            change(&document)
            #expect(document.pictureOnly == document, "\(name)")
            let own = try #require(Renderer.baseMapping(of: document, images: images), "\(name)")
            let picture = try #require(Renderer.baseMapping(of: document.pictureOnly, images: images), "\(name)")
            #expect(picture == own, "\(name)")
            let render = try #require(Renderer.renderPicture(of: document, images: images), "\(name)")
            #expect(render.mapping == own, "\(name)")
        }
    }

    @Test func aBackgroundIsLeftOutOfThePicturesMapping() throws {
        // Where it does differ: with a background the document's own render has a frame around the picture, which the picture
        // leaves out, so a finding's place in the picture's render is its place on the canvas.
        var (document, images) = document()
        document.background = background()
        let own = try #require(Renderer.baseMapping(of: document, images: images))
        let picture = try #require(Renderer.baseMapping(of: document.pictureOnly, images: images))
        #expect(own.renderedSize.width > 120 && own.toBase != .identity)
        #expect(picture.renderedSize == CGSize(width: 120, height: 80) && picture.toBase == .identity)
    }
}

private extension AnnotationObject {
    /// The rect of a redaction.
    var redactRect: CGRect {
        if case .redact(let redact) = kind { redact.rect } else { .zero }
    }
}

/// The identity a capture's saved document has, read from its folder without loading any image: what the Quick Access check
/// compares when the working copy is rewritten (Done in Annotate), to see whether the picture it checked is still the one.
final class PictureIdentityStorageTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "picture-identity-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func capture() throws -> HistoryItem {
        let details = HistoryWriter.Details(origin: .capture, captureKind: .selection, displayName: "Shot", savedURL: nil, scale: 2,
                                            appName: nil, isTransparent: false, globalRect: .zero, createdAt: Date())
        return try HistoryWriter.create(TestBitmaps.solid(40, 20, TestBitmaps.blue), details: details, root: root)
    }

    /// The capture annotated as `change` says and saved, as Done does it.
    func annotated(_ item: HistoryItem, _ change: (inout AnnotationDocument) -> Void) throws -> HistoryItem {
        var (document, images, _) = try AnnotationStorage.open(item, root: root)
        change(&document)
        let rendered = try #require(Renderer.render(document, images: images))
        return try AnnotationStorage.save(document, images: images, rendered: rendered, to: item, root: root)
    }

    @Test func aCaptureNeverAnnotatedHasNoDocumentToRead() throws {
        #expect(AnnotationStorage.pictureIdentity(of: try capture(), root: root) == nil)
    }

    @Test @MainActor func anAnnotatedCapturesIdentityIsThatOfItsPicture() throws {
        let item = try capture()
        let plain = PictureIdentity.plain(size: CGSize(width: 40, height: 20))
        let labelled = try annotated(item) {
            $0.objects = [AnnotationObject(kind: .filledRectangle(CGRect(x: 2, y: 2, width: 10, height: 10)),
                                           style: ObjectStyle(color: RGBAColor(red: 1, green: 0, blue: 0), lineWidth: 2, shadow: false))]
        }
        #expect(labelled.hasDocument == true)
        #expect(AnnotationStorage.pictureIdentity(of: labelled, root: root) == plain)
    }

    @Test @MainActor func aBackgroundAloneLeavesItAsItWas() throws {
        // A capture that got a background in Annotate: its working copy is bigger and different, its picture is the same.
        let item = try capture()
        let framed = try annotated(item) {
            $0.background = DocumentBackground(style: BackgroundStyle(fill: .color(RGBAColor(red: 0.6, green: 0.6, blue: 0.6)), padding: 20,
                                                                      inset: 0, insetColor: .color(RGBAColor(red: 1, green: 1, blue: 1)),
                                                                      shadow: 0, corners: 0, autoBalance: false, alignment: .center,
                                                                      ratio: .auto))
        }
        #expect(framed.pixelSize != item.pixelSize)
        #expect(AnnotationStorage.pictureIdentity(of: framed, root: root) == .plain(size: CGSize(width: 40, height: 20)))
    }

    @Test @MainActor func aTurnACropOrAMaskChangesIt() throws {
        let item = try capture()
        let plain = PictureIdentity.plain(size: CGSize(width: 40, height: 20))
        let turned = try annotated(item) { $0.imageOps = [.rotateRight] }
        #expect(AnnotationStorage.pictureIdentity(of: turned, root: root) != plain)
        let cropped = try annotated(item) { $0.canvasRect = CGRect(x: 5, y: 2, width: 30, height: 16) }
        #expect(AnnotationStorage.pictureIdentity(of: cropped, root: root) != plain)
        let masked = try annotated(item) { $0.objects = [AnnotationObject.pixelateMask(rect: CGRect(x: 4, y: 4, width: 20, height: 8), intensity: 4)] }
        #expect(AnnotationStorage.pictureIdentity(of: masked, root: root) != plain)
    }

    @Test @MainActor func aDocumentThatCantBeReadHasNoIdentity() throws {
        let item = try annotated(try capture()) { $0.objects = [] }
        #expect(AnnotationStorage.pictureIdentity(of: item, root: root) != nil)
        try Data("not json".utf8).write(to: item.folder(in: root).appending(path: DocumentPackage.documentFileName))
        #expect(AnnotationStorage.pictureIdentity(of: item, root: root) == nil)
        try FileManager.default.removeItem(at: item.folder(in: root).appending(path: DocumentPackage.documentFileName))
        #expect(AnnotationStorage.pictureIdentity(of: item, root: root) == nil)
    }


    // MARK: The same base-size correction as open

    /// The item annotated, with the base size the saved document records set to `recorded` (as a document that has drifted from
    /// its base image has it).
    func annotated(_ item: HistoryItem, recordingBaseSize recorded: CGSize) throws -> HistoryItem {
        try annotated(item) { $0.baseSize = recorded }
    }

    @Test @MainActor func theBaseSizeIsTheImagesNotTheOneTheDocumentRecords() throws {
        // `open` takes the base image's own size over the document's ("the base is ours"); the identity does too, so the two read
        // the same picture. The base image here is 40 x 20; the document says 10 x 10.
        let item = try annotated(try capture(), recordingBaseSize: CGSize(width: 10, height: 10))
        let opened = try AnnotationStorage.open(item, root: root)
        #expect(opened.document.baseSize == CGSize(width: 40, height: 20))
        #expect(AnnotationStorage.pictureIdentity(of: item, root: root) == opened.document.pictureIdentity)
        #expect(AnnotationStorage.pictureIdentity(of: item, root: root) == .plain(size: CGSize(width: 40, height: 20)))
    }

    @Test @MainActor func theIdentityIsTheOneOpenGivesForADocumentWithEverythingInIt() throws {
        let item = try annotated(try capture()) {
            $0.imageOps = [.rotateRight]
            $0.canvasRect = CGRect(x: 2, y: 3, width: 14, height: 30)
            $0.canvasFill = .transparent
            $0.objects = [AnnotationObject.pixelateMask(rect: CGRect(x: 4, y: 4, width: 20, height: 8), intensity: 4)]
        }
        let opened = try AnnotationStorage.open(item, root: root)
        #expect(AnnotationStorage.pictureIdentity(of: item, root: root) == opened.document.pictureIdentity)
    }

    @Test @MainActor func aBaseImageThatIsGoneLeavesNoIdentity() throws {
        let item = try annotated(try capture()) { $0.objects = [] }
        try FileManager.default.removeItem(at: item.folder(in: root).appending(path: AnnotationStorage.historyBase.name))
        #expect(AnnotationStorage.pictureIdentity(of: item, root: root) == nil)
    }

    // MARK: Reading a document without writing anything

    /// The names in the item's folder, and each file's size and date: what a read must leave alone.
    func snapshot(of item: HistoryItem) throws -> [String] {
        let folder = item.folder(in: root)
        return try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted().map { name in
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path(percentEncoded: false))
            return "\(name) \(attributes[.size] ?? 0) \(attributes[.modificationDate] ?? "")"
        }
    }

    @Test @MainActor func anAnnotatedCaptureIsReadWithItsDocumentAndImagesAndNothingIsWritten() throws {
        let item = try annotated(try capture()) { $0.imageOps = [.flipHorizontal] }
        let before = try snapshot(of: item)
        let read = try #require(AnnotationStorage.openReadOnly(item, root: root))
        #expect(read.document == (try AnnotationStorage.open(item, root: root)).document)
        #expect(read.images[read.document.base]?.width == 40)
        #expect(try snapshot(of: item) == before)
    }

    @Test func aCaptureNeverAnnotatedIsNotReadAndNoOriginalIsMadeForIt() throws {
        // `open` copies the working copy to `.original.png` for such a capture: a read for a scan must not.
        let item = try capture()
        let original = item.folder(in: root).appending(path: AnnotationStorage.historyBase.name)
        #expect(AnnotationStorage.openReadOnly(item, root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        // The contrast: opening it does.
        _ = try AnnotationStorage.open(item, root: root)
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
    }

    @Test @MainActor func anAnnotatedCaptureWhoseBaseIsGoneIsNotReadAndNothingIsCopiedBack() throws {
        // `open` takes this for a document that can't be read and copies the (annotated) working copy over the base; a scan's read
        // says there's nothing to read, and leaves the folder as it is.
        let item = try annotated(try capture()) { $0.objects = [] }
        let original = item.folder(in: root).appending(path: AnnotationStorage.historyBase.name)
        try FileManager.default.removeItem(at: original)
        let before = try snapshot(of: item)
        #expect(AnnotationStorage.openReadOnly(item, root: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
        #expect(try snapshot(of: item) == before)
        // The contrast: opening it copies the annotated working copy back as the base.
        let opened = try AnnotationStorage.open(item, root: root)
        #expect(opened.recovered)
        #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
    }

    @Test @MainActor func aDocumentThatCantBeReadIsNotReadAndNothingIsWritten() throws {
        let item = try annotated(try capture()) { $0.objects = [] }
        try Data("not json".utf8).write(to: item.folder(in: root).appending(path: DocumentPackage.documentFileName))
        let before = try snapshot(of: item)
        #expect(AnnotationStorage.openReadOnly(item, root: root) == nil)
        #expect(try snapshot(of: item) == before)
    }
}
