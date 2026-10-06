import AppKit
import CSCapture

/// Send to Raycast AI Chat: copy the image, open AI Chat, and say to paste it.
enum RaycastBridge {
    static let aiChatURL = URL(string: "raycast://extensions/raycast/raycast-ai/ai-chat")!

    /// Returns false, after saying so, when Raycast isn't installed or the copy or the opening fails.
    @discardableResult
    static func send(pngData: Data, hud: HUDController) -> Bool {
        guard NSWorkspace.shared.urlForApplication(toOpen: aiChatURL) != nil else {
            hud.show("Raycast isn't installed", symbol: "exclamationmark.triangle.fill")
            return false
        }
        guard ClipboardWriter.write(pngData: pngData, fileURL: nil, mode: .imageOnly) else {
            hud.show("Couldn't copy the image for Raycast", symbol: "exclamationmark.triangle.fill")
            return false
        }
        guard NSWorkspace.shared.open(aiChatURL) else {
            hud.show("Couldn't open Raycast", symbol: "exclamationmark.triangle.fill")
            return false
        }
        hud.show("Image copied — paste it into AI Chat", symbol: "sparkles")
        return true
    }
}
