import AppKit
import CSCore
import SwiftUI

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("ClearShot").font(.largeTitle.bold())
            Text("Version \(Bundle.main.versionString)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text("A screenshot and screen recording app for macOS.")
                .foregroundStyle(.secondary)
            Button("Show logs in Finder") {
                try? FileManager.default.createDirectory(at: FileLogSink.shared.directory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(FileLogSink.shared.directory)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
