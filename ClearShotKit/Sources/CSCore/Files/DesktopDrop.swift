import Foundation

/// Files dropped on the desktop cover go into ~/Desktop, modelled on Finder's Keep Both.
public enum DesktopDrop {
    public enum Operation: Equatable, Sendable {
        case move, copy
    }

    /// The trailing numbers read as an earlier copy's counter. Larger ones (a year, a camera's file number) are part of
    /// the name.
    private static let copyCounters = 2...99

    /// Move on the same volume; copy across volumes or with ⌥. When the source doesn't allow the wanted operation the
    /// other one is used, and nil refuses the drop: the source allows neither, or the file is already on the desktop.
    public static func operation(sameVolume: Bool, optionHeld: Bool, sourceAllowsMove: Bool, sourceAllowsCopy: Bool,
                                 alreadyThere: Bool) -> Operation? {
        guard !alreadyThere else { return nil }
        let order: [Operation] = !sameVolume || optionHeld ? [.copy, .move] : [.move, .copy]
        return order.first { $0 == .move ? sourceAllowsMove : sourceAllowsCopy }
    }

    /// `name`, or its " 2", " 3"… form when it is `taken` (names compare ignoring case, as on APFS).
    ///
    /// With `splitsExtension` (a file, not a folder) the number goes before the last extension, unless the last dot
    /// starts or ends the name. A name already ending in a copy counter " N" (N from 2 to 99, written without leading
    /// zeros) counts on from N + 1, so "Shot 2.png" becomes "Shot 3.png" rather than "Shot 2 2.png". Any other trailing
    /// number stays part of the name: "Report 2024.pdf" becomes "Report 2024 2.pdf", not "Report 2025.pdf".
    public static func destinationName(for name: String, splitsExtension: Bool, taken: Set<String>) -> String {
        let takenNames = Set(taken.map { $0.lowercased() })
        func isFree(_ candidate: String) -> Bool { !takenNames.contains(candidate.lowercased()) }
        if isFree(name) { return name }

        var stem = Substring(name)
        var fileExtension = Substring("")
        if splitsExtension, let dot = name.lastIndex(of: "."),
           dot != name.startIndex, name.index(after: dot) != name.endIndex {
            stem = name[..<dot]
            fileExtension = name[dot...]
        }

        var base = stem
        var number = 2
        if let space = stem.lastIndex(of: " ") {
            let digits = stem[stem.index(after: space)...]
            if let existing = Int(digits), copyCounters.contains(existing), String(existing) == digits {
                base = stem[..<space]
                number = existing + 1
            }
        }

        while true {
            let candidate = "\(base) \(number)\(fileExtension)"
            if isFree(candidate) { return candidate }
            number += 1
        }
    }

    /// Copies `source` to `destination`, a name that was free when it was given. A copy that fails partway (a full
    /// disk, a drive unplugged) removes what it left there, so a truncated file never sits under the real name, unless
    /// it failed because something else took the name first: that file isn't the copy's, so it stays. `source` is never
    /// touched. Throws the copy's error.
    public static func copyItem(at source: URL, to destination: URL) throws {
        let files = FileManager()
        do {
            try files.copyItem(at: source, to: destination)
        } catch {
            if (error as? CocoaError)?.code != .fileWriteFileExists { try? files.removeItem(at: destination) }
            throw error
        }
    }

    /// The alert for a drop's promised files that couldn't reach ~/Desktop, named `names`. `reason` is the error's
    /// description. They are kept in ClearShot's Undelivered Drops folder, or, if they couldn't be moved there either,
    /// left in the drop's temporary folder.
    public static func undeliveredAlert(names: [String], reason: String,
                                        inUndeliveredDrops: Bool) -> (message: String, detail: String) {
        let one = names.count == 1
        let message = one ? "Couldn't put “\(names[0])” on the Desktop" : "Couldn't put the files on the Desktop"
        let subject = one ? "It's" : "They're"
        let place = inUndeliveredDrops
            ? "kept in ClearShot's Undelivered Drops folder."
            : "in a temporary folder that macOS empties after a few days."
        return (message, "\(reason) \(subject) \(place)")
    }
}
