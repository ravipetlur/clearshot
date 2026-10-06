import AppKit
import CSCore

final class SoundPlayer {
    /// What copied text from Capture Text and Extract Text plays.
    private static let ocrSoundURL = URL(filePath: "/System/Library/Sounds/Purr.aiff")

    /// Where macOS keeps the sounds its own screen recording plays.
    private static let systemSoundsFolder = URL(
        filePath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system",
        directoryHint: .isDirectory)

    private let preferences: Preferences
    private var cache: [ShutterSound: NSSound] = [:]
    private var ocrSound: NSSound?
    /// The recording sounds, by file name.
    private var systemSounds: [String: NSSound] = [:]

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// The shutter sound, if "Play sounds" is on.
    func playShutter() {
        guard preferences[Prefs.playSounds] else { return }
        sound(for: preferences[Prefs.shutterSound])?.play()
    }

    /// The sound for text copied by Capture Text or Extract Text, if "Play sounds" is on.
    func playOCR() {
        guard preferences[Prefs.playSounds] else { return }
        if ocrSound == nil { ocrSound = NSSound(contentsOf: Self.ocrSoundURL, byReference: true) }
        ocrSound?.play()
    }

    /// A recording starting, pausing and stopping, if "Play sounds" is on. A recording's own file never has them: its
    /// system audio leaves out ClearShot's sound.
    func playRecordStart() { playSystemSound("begin_record.caf") }
    func playRecordPause() { playSystemSound("media_paused.caf") }
    func playRecordStop() { playSystemSound("end_record.caf") }

    func preview(_ sound: ShutterSound) {
        self.sound(for: sound)?.play()
    }

    private func playSystemSound(_ name: String) {
        guard preferences[Prefs.playSounds] else { return }
        if systemSounds[name] == nil {
            systemSounds[name] = NSSound(contentsOf: Self.systemSoundsFolder.appending(path: name), byReference: true)
        }
        systemSounds[name]?.play()
    }

    private func sound(for sound: ShutterSound) -> NSSound? {
        if let cached = cache[sound] { return cached }
        let loaded = NSSound(contentsOf: sound.fileURL, byReference: true)
        cache[sound] = loaded
        return loaded
    }
}
