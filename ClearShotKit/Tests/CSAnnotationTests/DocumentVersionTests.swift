import CoreGraphics
import Foundation
import Testing
@testable import CSAnnotation

/// The document's version: written at the lowest that holds it, older files read (and migrated), newer ones refused.
struct DocumentVersionTests {
    private static let style = ObjectStyle(color: .black, lineWidth: 4, shadow: false)

    private static func object(_ kind: ObjectKind, style: ObjectStyle = style) -> AnnotationObject {
        AnnotationObject(kind: kind, style: style)
    }

    /// The version a document is written with.
    private static func writtenVersion(of document: AnnotationDocument) throws -> Int? {
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any]
        return saved?["version"] as? Int
    }

    private static func document(with objects: [AnnotationObject]) -> AnnotationDocument {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: 2)
        document.objects = objects
        return document
    }

    @Test func versionsAreThreeAndTwo() {
        #expect(AnnotationDocument.currentVersion == 3)
        #expect(AnnotationDocument.baseVersion == 2)
        #expect(AnnotationDocument.formatFeatures.allSatisfy { $0.version <= AnnotationDocument.currentVersion })
    }

    // MARK: Reading older files

    @Test(arguments: [1, 2]) func olderDocumentsStillDecode(version: Int) throws {
        let json = AnnotationDocumentTests.versionOneJSON.replacingOccurrences(of: #""version":1"#, with: #""version":\#(version)"#)
        let decoded = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        #expect(decoded == AnnotationDocumentTests.fullDocument())
        #expect(decoded.version == AnnotationDocument.currentVersion)
    }

    @Test(arguments: [1, 2]) func olderPackagesStillOpen(version: Int) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "version-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = AnnotationDocumentTests.versionOneJSON.replacingOccurrences(of: #""version":1"#, with: #""version":\#(version)"#)
        try Data(json.utf8).write(to: folder.appending(path: DocumentPackage.documentFileName))
        #expect(try DocumentPackage.readDocument(from: folder) == AnnotationDocumentTests.fullDocument())
    }

    // MARK: Writing

    @Test func aDocumentWithOnlyOldFeaturesIsWrittenAsTheOldVersion() throws {
        var document = AnnotationDocumentTests.fullDocument()
        // A secrets mask and a curved arrow's bend were there before version 3.
        document.objects.append(.pixelateMask(rect: CGRect(x: 0, y: 0, width: 10, height: 10), intensity: 5))
        #expect(document.requiredVersion == 2)
        #expect(document.formatFeaturesUsed.isEmpty)
        #expect(try Self.writtenVersion(of: document) == 2)
        // A background is version 2 too.
        document.background = DocumentBackground(style: .standard)
        document.isWindowShot = true
        #expect(try Self.writtenVersion(of: document) == 2)
        // A plain empty document as well.
        #expect(try Self.writtenVersion(of: AnnotationDocument(baseSize: CGSize(width: 10, height: 10), pixelScale: 1)) == 2)
    }

    /// One object for each feature in `formatFeatures`, by name.
    static let newFeatures: [(name: String, object: AnnotationObject)] = [
        ("image opacity", object(.image(ImageObject(rect: CGRect(x: 0, y: 0, width: 8, height: 8), image: ImageRef(name: "images/a.png"),
                                                     opacity: 0.5)))),
        ("shape fill", object(.rectangle(CGRect(x: 0, y: 0, width: 20, height: 20)),
                              style: ObjectStyle(color: .black, lineWidth: 4, shadow: false, fillOpacity: 0.5))),
        ("hand-drawn shape", object(.ellipse(CGRect(x: 0, y: 0, width: 20, height: 20)),
                                    style: ObjectStyle(color: .black, lineWidth: 4, shadow: false, handDrawn: true, seed: 7))),
        ("hand-drawn text", object(.text(TextObject(origin: .zero, string: "Hi", style: .standard, fontSize: 20, handDrawn: true)))),
        ("bent arrow", object(.arrow(ArrowShape(start: .zero, end: CGPoint(x: 50, y: 0), control: CGPoint(x: 25, y: 20),
                                                style: .standard)))),
        ("ruler", object(.ruler(RulerObject(start: .zero, end: CGPoint(x: 50, y: 0))))),
        ("magnifier", object(.magnifier(MagnifierObject(source: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                        callout: CGRect(x: 40, y: 40, width: 40, height: 40))))),
    ]

    @Test func everyNewFeatureForcesVersionThree() throws {
        // Every feature listed has an object here, apart from the redaction hook, which nothing uses yet.
        let listed = Set(AnnotationDocument.formatFeatures.map(\.name)).subtracting(["redaction"])
        #expect(Set(Self.newFeatures.map(\.name)) == listed)
        for (name, object) in Self.newFeatures {
            var document = AnnotationDocumentTests.fullDocument()
            document.objects.append(object)
            #expect(document.requiredVersion == 3, "\(name)")
            #expect(document.formatFeaturesUsed == [name])
            #expect(try Self.writtenVersion(of: document) == 3, "\(name)")
            // It reads back as it was.
            #expect(try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(document)) == document, "\(name)")
        }
    }

    @Test func theDefaultsOfTheNewFieldsDontForceIt() {
        let plain: [AnnotationObject] = [
            Self.object(.image(ImageObject(rect: CGRect(x: 0, y: 0, width: 8, height: 8), image: ImageRef(name: "images/a.png")))),
            Self.object(.arrow(ArrowShape(start: .zero, end: CGPoint(x: 50, y: 0), style: .fancy))),
            Self.object(.text(TextObject(origin: .zero, string: "Hi", style: .standard, fontSize: 20))),
            // A seed alone draws nothing differently.
            Self.object(.rectangle(.zero), style: ObjectStyle(color: .black, lineWidth: 4, shadow: false, seed: 3)),
        ]
        #expect(Self.document(with: plain).requiredVersion == 2)
    }

    @Test func everyRedactionStyleNeedsTheBaseVersionToday() {
        for style in RedactStyle.allCases {
            let redact = RedactObject(rect: CGRect(x: 0, y: 0, width: 10, height: 10), style: style, intensity: 5)
            #expect(AnnotationDocument.requiredVersion(of: redact) == 2)
            #expect(Self.document(with: [Self.object(.redact(redact))]).requiredVersion == 2)
        }
    }

    @Test func aTextOnlyRedactionNeedsVersionThree() {
        for style in RedactStyle.allCases {
            var redact = RedactObject(rect: CGRect(x: 0, y: 0, width: 10, height: 10), style: style, intensity: 5)
            redact.textOnly = true
            #expect(AnnotationDocument.requiredVersion(of: redact) == 3)
            #expect(Self.document(with: [Self.object(.redact(redact))]).requiredVersion == 3)
        }
    }

    // MARK: Refusing newer files

    @Test func aVersionThreeDocumentIsRefusedByABuildThatKnowsVersionTwo() throws {
        let document = Self.document(with: [Self.object(.ruler(RulerObject(start: .zero, end: CGPoint(x: 50, y: 0))))])
        let written = try #require(try Self.writtenVersion(of: document))
        #expect(written == 3)
        // The check `DocumentPackage.readDocument` makes, as a version-2 build makes it.
        #expect(!AnnotationDocument.canRead(version: written, newest: 2))
        #expect(AnnotationDocument.canRead(version: written))
        // A document with nothing new is still read there.
        let plain = try #require(try Self.writtenVersion(of: AnnotationDocumentTests.fullDocument()))
        #expect(AnnotationDocument.canRead(version: plain, newest: 2))
    }

    @Test func aNewerPackageIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "version-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let json = AnnotationDocumentTests.versionOneJSON.replacingOccurrences(of: #""version":1"#, with: #""version":4"#)
        try Data(json.utf8).write(to: folder.appending(path: DocumentPackage.documentFileName))
        #expect(throws: DocumentError.newerVersion) { try DocumentPackage.readDocument(from: folder) }
    }

    // MARK: Migration

    private static func arrowJSON(style: ArrowStyle, version: Int) -> String {
        #"""
        {"version":\#(version),"baseSize":[200,100],"pixelScale":2,"objects":[{"id":"00000000-0000-0000-0000-000000000001",\#
        "kind":{"arrow":{"_0":{"control":[25,20],"end":[50,0],"start":[0,0],"style":"\#(style.rawValue)"}}},\#
        "style":{"color":{"alpha":1,"blue":0,"green":0,"red":0},"lineWidth":4,"shadow":false}}]}
        """#
    }

    private static func control(in json: String) throws -> CGPoint? {
        let document = try JSONDecoder().decode(AnnotationDocument.self, from: Data(json.utf8))
        guard case .arrow(let arrow) = try #require(document.objects.first).kind else { return nil }
        return arrow.control
    }

    @Test(arguments: [1, 2]) func anOlderDocumentsStraightArrowsLoseTheirLeftoverBend(version: Int) throws {
        // Switching a curved arrow to another style used to keep its control point, unseen; it would now bend the arrow.
        for style in ArrowStyle.allCases where style != .curved {
            #expect(try Self.control(in: Self.arrowJSON(style: style, version: version)) == nil)
        }
        // A curved arrow keeps its bend.
        #expect(try Self.control(in: Self.arrowJSON(style: .curved, version: version)) == CGPoint(x: 25, y: 20))
    }

    @Test func aVersionThreeDocumentKeepsEveryArrowsBend() throws {
        for style in ArrowStyle.allCases {
            #expect(try Self.control(in: Self.arrowJSON(style: style, version: 3)) == CGPoint(x: 25, y: 20))
        }
    }
}
