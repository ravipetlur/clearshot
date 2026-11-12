import CoreGraphics
import CSCapture
import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSAnnotation

/// The background in the document: its types, the gradient catalog, tolerant decoding, the document's version and
/// stored pictures, and the preset lists.
struct BackgroundModelTests {
    static func decodeStyle(_ json: String, using decoder: JSONDecoder = JSONDecoder()) throws -> BackgroundStyle {
        try decoder.decode(BackgroundStyle.self, from: Data(json.utf8))
    }

    /// A style with every field away from `standard`.
    static func unusualStyle() -> BackgroundStyle {
        var style = BackgroundStyle.standard
        style.fill = .color(RGBAColor(red: 0.2, green: 0.4, blue: 0.6))
        style.padding = 40
        style.inset = 8
        style.insetColor = .color(RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        style.shadow = 30
        style.corners = 20
        style.autoBalance = true
        style.alignment = .topRight
        style.ratio = .r16x9
        return style
    }

    /// A JSON object as a string, so a test can edit a field by hand.
    static func json(_ object: [String: Any]) throws -> String {
        try String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        return try #require(object)
    }

    /// A decoder that reads "inf" and "nan" as numbers, so non-finite values can reach the decoders.
    static func nonConformingDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// A temporary folder, removed by the caller.
    static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "backgrounds-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    // MARK: The document

    @Test func aVersionOneDocumentDecodesWithoutABackground() throws {
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(AnnotationDocumentTests.versionOneJSON.utf8))
        #expect(decoded.background == nil)
        #expect(decoded.isWindowShot == false)
        #expect(decoded == AnnotationDocumentTests.fullDocument())
        // Saved again, it has no background and says it isn't a window shot.
        let saved = try Self.jsonObject(decoded)
        #expect(saved["background"] == nil)
        #expect(saved["isWindowShot"] as? Bool == false)
    }

    static let everyFill: [BackgroundFill] = [
        .none,
        .color(RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)),
        .gradient(.standard),
        .gradient(BackgroundGradient(kind: .radial, stops: [
            BackgroundGradient.Stop(color: .white, location: 0), BackgroundGradient.Stop(color: .black, location: 0.4),
            BackgroundGradient.Stop(color: RGBAColor(red: 1, green: 0, blue: 0), location: 1),
        ])),
        .desktop,
        .blurredDesktop,
        .systemWallpaper(fileName: "Sequoia Sunrise.heic"),
        .custom(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!),
        .windowWallpaper,
        .blurredScreenshot,
    ]

    @Test(arguments: everyFill) func aBackgroundedDocumentIsWrittenAsVersionTwo(fill: BackgroundFill) throws {
        var document = AnnotationDocumentTests.fullDocument()
        var style = Self.unusualStyle()
        style.fill = fill
        document.background = DocumentBackground(style: style, image: fill.isImageBacked ? ImageRef(name: "images/background-a.jpg") : nil)
        document.isWindowShot = true
        let data = try JSONEncoder().encode(document)
        let saved = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(AnnotationDocument.baseVersion == 2)
        #expect(saved["version"] as? Int == 2)
        #expect(saved["isWindowShot"] as? Bool == true)
        #expect(saved["background"] != nil)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: data)
        #expect(decoded == document)
        #expect(decoded.background?.style.fill == fill)
    }

    @Test func aWrongShapedBackgroundIsDroppedNotFatal() throws {
        var object = try #require(JSONSerialization.jsonObject(with: Data(AnnotationDocumentTests.versionOneJSON.utf8)) as? [String: Any])
        object["background"] = 7
        object["isWindowShot"] = "yes"
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(Self.json(object).utf8))
        #expect(decoded.background == nil)
        #expect(decoded.isWindowShot == false)
        #expect(decoded == AnnotationDocumentTests.fullDocument())
        // A background whose style isn't an object is dropped the same way.
        object["background"] = ["style": "wide"]
        let alsoDecoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(Self.json(object).utf8))
        #expect(alsoDecoded.background == nil)
    }

    @Test func aBackgroundWithNonFiniteNumbersIsNotWellFormed() {
        var document = AnnotationDocument(baseSize: CGSize(width: 640, height: 480), pixelScale: 2)
        document.background = DocumentBackground(style: .standard)
        #expect(document.isWellFormed)
        var style = BackgroundStyle.standard
        style.padding = .nan
        document.background = DocumentBackground(style: style)
        #expect(!document.isWellFormed)
        // Every number in the style counts: the other lengths, the colours, and the gradient's angle and stops.
        let edits: [(inout BackgroundStyle) -> Void] = [
            { $0.inset = .infinity }, { $0.shadow = -Double.infinity }, { $0.corners = .nan },
            { $0.insetColor = .color(RGBAColor(red: .nan, green: 0, blue: 0)) },
            { $0.fill = .color(RGBAColor(red: 0, green: 0, blue: 0, alpha: .infinity)) },
            { $0.fill = .gradient(BackgroundGradient(kind: .linear(angle: .nan), stops: BackgroundGradient.standard.stops)) },
            { $0.fill = .gradient(BackgroundGradient(kind: .radial, stops: [BackgroundGradient.Stop(color: .white, location: .nan),
                                                                            BackgroundGradient.Stop(color: .black, location: 1)])) },
            { $0.fill = .gradient(BackgroundGradient(kind: .radial, stops: [
                BackgroundGradient.Stop(color: RGBAColor(red: 0, green: .infinity, blue: 0), location: 0),
                BackgroundGradient.Stop(color: .black, location: 1),
            ])) },
        ]
        for edit in edits {
            var style = BackgroundStyle.standard
            edit(&style)
            document.background = DocumentBackground(style: style)
            #expect(!document.isWellFormed, "\(style)")
        }
    }

    // MARK: Stored pictures

    @Test func theBackgroundPictureIsAReference() throws {
        var document = AnnotationDocument(baseSize: CGSize(width: 4, height: 4), pixelScale: 1)
        let picture = ImageRef(name: "images/background-a.jpg")
        document.background = DocumentBackground(style: BackgroundStyle.windowStandard, image: picture)
        #expect(ImageStore.references(in: document) == [.original, picture])
        // Without a picture only the base is used.
        document.background = DocumentBackground(style: .standard)
        #expect(ImageStore.references(in: document) == [.original])

        // A document.json naming a picture outside the package is unreadable.
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = folder.appending(path: "Hostile.clearshot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try ImageEncoder.encode(TestBitmaps.solid(4, 4, TestBitmaps.red), as: .png, quality: 1)
            .write(to: package.appending(path: ImageRef.original.name))
        document.background = DocumentBackground(style: BackgroundStyle.windowStandard, image: ImageRef(name: "../x.jpg"))
        try JSONEncoder().encode(document).write(to: package.appending(path: DocumentPackage.documentFileName))
        #expect(throws: DocumentError.unreadable(package.path(percentEncoded: false))) {
            try DocumentPackage.readDocument(from: package)
        }
    }

    /// Writes a document whose background picture is `name` and returns the written file's bytes and the picture read back.
    static func writePicture(named name: String) throws -> (bytes: Data, read: CGImage?) {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var (document, images) = TestBitmaps.document(base: TestBitmaps.solid(40, 30, TestBitmaps.blue))
        let picture = ImageRef(name: name)
        images.set(TestBitmaps.noise(24, 16), for: picture)
        document.background = DocumentBackground(style: BackgroundStyle.windowStandard, image: picture)
        try DocumentPackage.writeContents(document, images: images, to: folder)
        let bytes = try Data(contentsOf: folder.appending(path: name))
        return (bytes, ImageStore.load(for: document, from: folder)[picture])
    }

    /// A ".jpg" name, in either case, is written as JPEG; every other name, ".jpeg" included, stays PNG. Either way the
    /// picture reads back at its size.
    @Test(arguments: [("images/background-a.jpg", [UInt8]([0xFF, 0xD8, 0xFF])), ("images/background-b.JPG", [0xFF, 0xD8, 0xFF]),
                      ("images/background-a.png", [0x89, 0x50, 0x4E, 0x47]), ("images/background-a.jpeg", [0x89, 0x50, 0x4E, 0x47])])
    func aPictureIsWrittenInTheFormatItsNameSays(name: String, signature: [UInt8]) throws {
        let (bytes, read) = try Self.writePicture(named: name)
        #expect(Array(bytes.prefix(signature.count)) == signature)
        #expect(read?.width == 24)
        #expect(read?.height == 16)
    }

    // MARK: Styles

    @Test func styleNumbersAreClampedIntoRange() throws {
        let decoded = try Self.decodeStyle(#"{"padding":999,"inset":-5,"shadow":150,"corners":80}"#)
        #expect(decoded.padding == 256)
        #expect(decoded.inset == 0)
        #expect(decoded.shadow == 100)
        #expect(decoded.corners == 64)

        // `clamped()` does the same for a style made in code, and a non-finite number becomes the standard's.
        var style = BackgroundStyle.standard
        style.padding = 999
        style.inset = -5
        style.shadow = .infinity
        style.corners = .nan
        let clamped = style.clamped()
        #expect(clamped.padding == 256)
        #expect(clamped.inset == 0)
        #expect(clamped.shadow == 50)
        #expect(clamped.corners == 12)
        #expect(BackgroundStyle.standard.clamped() == .standard)

        // Non-finite numbers in a file are the standard's too.
        let nonFinite = try Self.decodeStyle(#"{"padding":"nan","inset":"inf","shadow":"-inf","corners":30}"#,
                                             using: Self.nonConformingDecoder())
        #expect(nonFinite.padding == 64)
        #expect(nonFinite.inset == 0)
        #expect(nonFinite.shadow == 50)
        #expect(nonFinite.corners == 30)
    }

    @Test func aDamagedFieldResetsOnlyItself() throws {
        let style = Self.unusualStyle()
        var object = try Self.jsonObject(style)
        object["alignment"] = "middle"
        object["padding"] = "wide"
        let decoded = try Self.decodeStyle(Self.json(object))
        var expected = style
        expected.alignment = .center
        expected.padding = 64
        #expect(decoded == expected)
        // A missing field takes the standard's value as well.
        object.removeValue(forKey: "ratio")
        object.removeValue(forKey: "insetColor")
        let missing = try Self.decodeStyle(Self.json(object))
        expected.ratio = .auto
        expected.insetColor = .auto
        #expect(missing == expected)
        // And an empty object is the standard style.
        #expect(try Self.decodeStyle("{}") == .standard)
    }

    @Test func anUnknownFillFallsBackToTheStandardGradient() throws {
        let decoded = try Self.decodeStyle(#"{"fill":{"hologram":{}},"padding":10}"#)
        #expect(decoded.fill == .gradient(.standard))
        #expect(decoded.padding == 10)
        #expect(try Self.decodeStyle(#"{"fill":5}"#).fill == .gradient(.standard))
    }

    /// A style whose fill is a gradient with these stops, as JSON.
    static func gradientStyleJSON(stops: [(red: Double, location: Double)], kind: String = #"{"radial":{}}"#) -> String {
        let stops = stops.map { #"{"color":{"red":\#($0.red),"green":0.5,"blue":0.5,"alpha":1},"location":\#($0.location)}"# }
        return #"{"fill":{"gradient":{"_0":{"kind":\#(kind),"stops":[\#(stops.joined(separator: ","))]}}}}"#
    }

    @Test func gradientStopsAreClampedSortedAndLimited() throws {
        let json = Self.gradientStyleJSON(stops: [(0.1, 0.9), (0.2, 1.4), (1.5, 0.05), (0.4, 0.5), (0.5, 0.3), (-0.2, 0.0),
                                                  (0.7, 0.3), (0.8, 0.2)])
        let decoded = try Self.decodeStyle(json)
        guard case .gradient(let gradient) = decoded.fill else { Issue.record("not a gradient: \(decoded.fill)"); return }
        #expect(gradient.stops.count == 6)
        let locations = gradient.stops.map(\.location)
        #expect(locations == locations.sorted())
        #expect(locations.allSatisfy { (0...1).contains($0) })
        let last = try #require(locations.last)
        #expect(last <= 1)
        // Clamped, then sorted (equal locations keep their order), then the first six.
        #expect(locations == [0, 0.05, 0.2, 0.3, 0.3, 0.5])
        #expect(gradient.stops.map(\.color.red) == [0, 1, 0.8, 0.5, 0.7, 0.4])
        let components = gradient.stops.flatMap { [$0.color.red, $0.color.green, $0.color.blue, $0.color.alpha] }
        #expect(components.allSatisfy { (0...1).contains($0) })

        // With few enough stops, every one is kept, its location clamped.
        let few = try Self.decodeStyle(Self.gradientStyleJSON(stops: [(0.1, -0.5), (0.2, 1.4), (0.3, 0.5)]))
        guard case .gradient(let clamped) = few.fill else { Issue.record("not a gradient: \(few.fill)"); return }
        #expect(clamped.stops.map(\.location) == [0, 0.5, 1])
        #expect(clamped.stops.map(\.color.red) == [0.1, 0.3, 0.2])
    }

    @Test func aGradientWithOneStopFallsBack() throws {
        let decoded = try Self.decodeStyle(Self.gradientStyleJSON(stops: [(0.2, 0)]))
        #expect(decoded.fill == .gradient(.standard))
        // On its own the gradient refuses to decode.
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BackgroundGradient.self, from: Data(#"{"kind":{"radial":{}},"stops":[]}"#.utf8))
        }
        // Two stops are enough.
        let two = try Self.decodeStyle(Self.gradientStyleJSON(stops: [(0.2, 0), (0.4, 1)]))
        #expect(two.fill != .gradient(.standard))
    }

    @Test func gradientAnglesAreReducedAndANonFiniteOneIsZero() throws {
        let cases: [(written: String, angle: Double)] = [("45", 45), ("405", 45), ("-90", 270), ("720", 0), ("360", 0),
                                                         (#""nan""#, 0), (#""inf""#, 0)]
        for (written, angle) in cases {
            let json = Self.gradientStyleJSON(stops: [(0.2, 0), (0.4, 1)], kind: #"{"linear":{"angle":\#(written)}}"#)
            let decoded = try Self.decodeStyle(json, using: Self.nonConformingDecoder())
            #expect(decoded.fill == .gradient(BackgroundGradient(kind: .linear(angle: angle), stops: [
                BackgroundGradient.Stop(color: RGBAColor(red: 0.2, green: 0.5, blue: 0.5), location: 0),
                BackgroundGradient.Stop(color: RGBAColor(red: 0.4, green: 0.5, blue: 0.5), location: 1),
            ])), "\(written)")
        }
    }

    @Test(arguments: ["../x.heic", "", ".", "..", "a/b.heic", "x\0.heic"])
    func aSystemWallpaperNameWithASlashFallsBack(name: String) throws {
        let object: [String: Any] = ["fill": ["systemWallpaper": ["fileName": name]], "padding": 10]
        let decoded = try Self.decodeStyle(Self.json(object))
        #expect(decoded.fill == .gradient(.standard))
        #expect(decoded.padding == 10)
    }

    @Test func aPlainSystemWallpaperNameIsKept() throws {
        let object: [String: Any] = ["fill": ["systemWallpaper": ["fileName": "Sequoia Sunrise.heic"]]]
        #expect(try Self.decodeStyle(Self.json(object)).fill == .systemWallpaper(fileName: "Sequoia Sunrise.heic"))
    }

    @Test func ratiosAndAlignmentFactors() throws {
        let aspects: [(BackgroundRatio, Double?)] = [(.auto, nil), (.square, 1), (.r3x4, 0.75), (.r4x3, 4.0 / 3), (.r3x2, 1.5),
                                                     (.r5x4, 1.25), (.r16x9, 16.0 / 9), (.r4x5, 0.8), (.r9x16, 0.5625)]
        for (ratio, aspect) in aspects {
            #expect(ratio.aspect == aspect, "\(ratio)")
        }
        #expect(try JSONEncoder().encode(BackgroundRatio.r16x9) == Data(#""16:9""#.utf8))

        func factor(_ alignment: BackgroundAlignment) -> [Double] { [alignment.factor.x, alignment.factor.y] }
        #expect(factor(.topLeft) == [0, 0])
        #expect(factor(.top) == [0.5, 0])
        #expect(factor(.topRight) == [1, 0])
        #expect(factor(.left) == [0, 0.5])
        #expect(factor(.center) == [0.5, 0.5])
        #expect(factor(.right) == [1, 0.5])
        #expect(factor(.bottomLeft) == [0, 1])
        #expect(factor(.bottom) == [0.5, 1])
        #expect(factor(.bottomRight) == [1, 1])
    }

    @Test func onlyThePicturedFillsAreImageBacked() {
        let imageBacked = Self.everyFill.filter(\.isImageBacked)
        #expect(imageBacked == [.desktop, .blurredDesktop, .systemWallpaper(fileName: "Sequoia Sunrise.heic"),
                                .custom(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00CF4FC964FF")!), .windowWallpaper])
    }

    // MARK: The gradient catalog

    @Test func aGradientOutsideTheCatalogIsTitledGradient() {
        var gradient = BackgroundGradient.standard
        #expect(gradient.title == "Coral")
        gradient.id = nil
        #expect(gradient.title == "Gradient")
        gradient.id = "nebula"
        #expect(gradient.title == "Gradient")
        // The id is part of what a gradient is: the catalog's and the same colours without the id differ.
        #expect(BackgroundGradient(id: nil, kind: BackgroundGradient.standard.kind, stops: BackgroundGradient.standard.stops)
            != .standard)
    }

    /// Every catalog gradient has an id of its own, and two to six stops, ascending, in range.
    @Test func everyCatalogGradientHasAUniqueIDAndTwoToSixAscendingStopsInRange() throws {
        let ids = BackgroundGradient.catalog.compactMap(\.id)
        #expect(ids.count == BackgroundGradient.catalog.count)
        #expect(Set(ids).count == ids.count)
        for gradient in BackgroundGradient.catalog {
            #expect((2...6).contains(gradient.stops.count), "\(gradient.title)")
            let locations = gradient.stops.map(\.location)
            #expect(locations == locations.sorted(), "\(gradient.title)")
            #expect(locations.first == 0 && locations.last == 1, "\(gradient.title)")
            let components = gradient.stops.flatMap { [$0.color.red, $0.color.green, $0.color.blue, $0.color.alpha] }
            #expect(components.allSatisfy { (0...1).contains($0) }, "\(gradient.title)")
            // Decoding changes nothing about a catalog gradient.
            let decoded = try JSONDecoder().decode(BackgroundGradient.self, from: JSONEncoder().encode(gradient))
            #expect(decoded == gradient, "\(gradient.title)")
        }
    }

    // MARK: The panel

    @Test func onlyAColorOutsideTheSwatchesIsTheCustomColor() {
        for swatch in BackgroundFill.colorSwatches {
            #expect(!BackgroundFill.color(swatch).isCustomColor, "\(swatch.hex)")
        }
        #expect(BackgroundFill.color(RGBAColor(red: 0.2, green: 0.4, blue: 0.6)).isCustomColor)
        // A swatch at another opacity is a colour of its own.
        #expect(BackgroundFill.color(RGBAColor.white.withAlpha(0.5)).isCustomColor)
        // Only colours are.
        let others = Self.everyFill.filter { if case .color = $0 { false } else { true } }
        #expect(others.count == Self.everyFill.count - 1)
        #expect(others.allSatisfy { !$0.isCustomColor })
    }

    static let typedPaddings: [(text: String, value: Double)] = [
        ("64", 64), (" 12 ", 12), ("12.4", 12), ("12.5", 13), ("0", 0), ("256", 256), ("300", 256), ("-5", 0), ("1e9", 256),
        // Too many digits to be anything but infinity.
        (String(repeating: "9", count: 400), 256),
    ]

    @Test(arguments: typedPaddings)
    func typedValuesAreWholeNumbersClampedIntoRange(text: String, expected: Double) {
        #expect(BackgroundStyle.typedValue(text, in: BackgroundStyle.paddingRange) == expected)
    }

    @Test func aTypedValueIsClampedToItsOwnRange() {
        #expect(BackgroundStyle.typedValue("200", in: BackgroundStyle.insetRange) == 128)
        #expect(BackgroundStyle.typedValue("200", in: BackgroundStyle.shadowRange) == 100)
        #expect(BackgroundStyle.typedValue("200", in: BackgroundStyle.cornersRange) == 64)
        #expect(BackgroundStyle.typedValue("200", in: BackgroundStyle.paddingRange) == 200)
    }

    @Test(arguments: ["", "  ", "abc", "12px", "1,5", "nan"])
    func textThatIsNotANumberIsRefused(text: String) {
        #expect(BackgroundStyle.typedValue(text, in: BackgroundStyle.paddingRange) == nil)
    }

    // MARK: Presets

    @Test func aPresetListDropsUndecodableEntries() throws {
        let first = BackgroundPreset(name: "First", style: .standard)
        let third = BackgroundPreset(name: "Third", style: Self.unusualStyle())
        let repeated = BackgroundPreset(id: first.id, name: "Again", style: BackgroundStyle.windowStandard)
        let object: [String: Any] = [
            "presets": [
                try Self.jsonObject(first),
                ["id": "not a uuid", "name": "Broken", "style": [String: Any]()],
                try Self.jsonObject(third),
                try Self.jsonObject(repeated),
            ],
        ]
        let decoded = try JSONDecoder().decode(BackgroundPresetList.self, from: Data(Self.json(object).utf8))
        #expect(decoded.presets == [first, third])
        // Nothing usable is an empty list, not a failure.
        #expect(try JSONDecoder().decode(BackgroundPresetList.self, from: Data(#"{"presets":7}"#.utf8)) == BackgroundPresetList())
        #expect(try JSONDecoder().decode(BackgroundPresetList.self, from: Data("{}".utf8)) == BackgroundPresetList())
    }

    @Test func presetListOperations() throws {
        var list = BackgroundPresetList()
        let first = list.add(name: "  ", style: .standard)
        #expect(first.name == "Preset 1")
        let second = list.add(name: "  Window look \n", style: BackgroundStyle.windowStandard)
        #expect(second.name == "Window look")
        #expect(list.presets.map(\.id) == [first.id, second.id])
        #expect(list.add(name: "", style: .standard).name == "Preset 3")

        #expect(list.preset(id: second.id) == second)
        #expect(list.preset(id: UUID()) == nil)
        #expect(list.preset(idString: "") == nil)
        #expect(list.preset(idString: "x") == nil)
        #expect(list.preset(idString: UUID().uuidString) == nil)
        #expect(list.preset(idString: second.id.uuidString) == second)

        // `matching` finds the first preset with exactly that style.
        #expect(list.matching(.standard)?.id == first.id)
        #expect(list.matching(Self.unusualStyle()) == nil)
        list.update(second.id, style: Self.unusualStyle())
        #expect(list.preset(id: second.id)?.style == Self.unusualStyle())
        #expect(list.matching(Self.unusualStyle())?.id == second.id)
        list.update(UUID(), style: .standard)
        #expect(list.presets.count == 3)

        list.rename(first.id, to: "  Bright ")
        #expect(list.preset(id: first.id)?.name == "Bright")
        list.rename(first.id, to: " \n ")
        #expect(list.preset(id: first.id)?.name == "Bright")

        list.remove(first.id)
        #expect(list.preset(id: first.id) == nil)
        #expect(list.presets.count == 2)
        #expect(list.matching(.standard)?.name == "Preset 3")
        // A new preset after a removal is numbered from the count.
        #expect(list.add(name: "", style: .standard).name == "Preset 3")
    }

    @MainActor @Test func presetsAndPreviousSettingsPersist() {
        withThrowawayDefaults("backgrounds") { defaults in
            let prefs = Preferences(defaults: defaults)
            var list = BackgroundPresetList()
            list.add(name: "Mine", style: Self.unusualStyle())
            prefs[Prefs.windowBackgroundPresets] = list
            prefs[Prefs.lastBackgroundStyle] = RememberedBackgroundStyle(Self.unusualStyle())
            let reopened = Preferences(defaults: defaults)
            #expect(reopened[Prefs.windowBackgroundPresets] == list)
            #expect(reopened[Prefs.backgroundPresets] == BackgroundPresetList())
            #expect(reopened[Prefs.lastBackgroundStyle].style == Self.unusualStyle())
            #expect(reopened[Prefs.lastWindowBackgroundStyle].style == nil)
        }
    }

    @Test func presetKindsUseTheirOwnKeys() {
        let screenshot = BackgroundPresetKind.screenshot, window = BackgroundPresetKind.window
        #expect(screenshot.presetsKey.name == Prefs.backgroundPresets.name)
        #expect(screenshot.previousKey.name == Prefs.lastBackgroundStyle.name)
        #expect(screenshot.autoApplyKey.name == Prefs.autoApplyBackgroundPresetID.name)
        #expect(screenshot.standardStyle == .standard)
        #expect(window.presetsKey.name == Prefs.windowBackgroundPresets.name)
        #expect(window.previousKey.name == Prefs.lastWindowBackgroundStyle.name)
        #expect(window.autoApplyKey.name == Prefs.autoApplyWindowBackgroundPresetID.name)
        #expect(window.standardStyle == BackgroundStyle.windowStandard)
        let names = [Prefs.backgroundPresets.name, Prefs.windowBackgroundPresets.name, Prefs.lastBackgroundStyle.name,
                     Prefs.lastWindowBackgroundStyle.name, Prefs.autoApplyBackgroundPresetID.name,
                     Prefs.autoApplyWindowBackgroundPresetID.name, Prefs.annotateBackgroundToolWasOpen.name]
        #expect(Set(names).count == names.count)
    }
}
