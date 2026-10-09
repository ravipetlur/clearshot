// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClearShotKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "CSCore", targets: ["CSCore"]),
        .library(name: "CSCapture", targets: ["CSCapture"]),
        .library(name: "CSHistory", targets: ["CSHistory"]),
        .library(name: "CSAnnotation", targets: ["CSAnnotation"]),
        .library(name: "CSOCR", targets: ["CSOCR"]),
        .library(name: "CSScrolling", targets: ["CSScrolling"]),
        .library(name: "CSRecording", targets: ["CSRecording"]),
        .library(name: "CSAPI", targets: ["CSAPI"]),
    ],
    targets: [
        .target(name: "CSCore"),
        .target(name: "CSCapture", dependencies: ["CSCore", "CSWebP"]),
        .target(name: "CSHistory", dependencies: ["CSCore", "CSCapture"]),
        .target(name: "CSAnnotation", dependencies: ["CSCore", "CSCapture", "CSHistory"]),
        .target(name: "CSOCR", dependencies: ["CSCore"]),
        // Scrolling capture: the stitcher and the auto-scroll rules. Pure; CSCore only names its queue.
        .target(name: "CSScrolling", dependencies: ["CSCore"]),
        // Screen recording: the recording preferences, the pure rules (encoder ceilings, pause re-basing, the hotkey
        // table, warnings, recovery, edit paths) and the writer.
        .target(name: "CSRecording", dependencies: ["CSCore", "CSCapture"]),
        // The clearshot:// URL API: the parser, areas and display numbers, file checks, sender naming, consent and the
        // launch inbox. Pure; nothing in the package depends on it, the app imports it.
        .target(name: "CSAPI", dependencies: ["CSCore"]),
        // Our own lossless WebP encoder, written from RFC 9649. Depends on nothing: RGBA bytes in, a .webp file out.
        .target(name: "CSWebP"),
        // What every test target shares: throwaway preferences.
        .target(name: "CSTestSupport", path: "Tests/CSTestSupport"),
        .testTarget(name: "CSCoreTests", dependencies: ["CSCore", "CSTestSupport"]),
        .testTarget(name: "CSCaptureTests", dependencies: ["CSCapture", "CSTestSupport"]),
        .testTarget(name: "CSHistoryTests", dependencies: ["CSHistory", "CSTestSupport"]),
        .testTarget(name: "CSAnnotationTests", dependencies: ["CSAnnotation", "CSHistory", "CSCapture", "CSCore", "CSTestSupport"]),
        // Fixtures/: Vision's readings of tiles, captured once, replayed through the merge.
        .testTarget(name: "CSOCRTests", dependencies: ["CSOCR", "CSCore", "CSTestSupport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CSScrollingTests", dependencies: ["CSScrolling"]),
        .testTarget(name: "CSRecordingTests", dependencies: ["CSRecording", "CSCore", "CSCapture", "CSTestSupport"]),
        .testTarget(name: "CSAPITests", dependencies: ["CSAPI", "CSCore", "CSTestSupport"]),
        // Decodes the encoder's files with ImageIO and compares the pixels.
        .testTarget(name: "CSWebPTests", dependencies: ["CSWebP"]),
    ]
)
