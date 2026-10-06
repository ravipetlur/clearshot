import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSAnnotation

struct ToolKeysTests {
    @Test func theDefaultsAreTheM4aLettersPlusCForCrop() {
        let keys = AnnotateToolKeys()
        let letters = EditorTool.allCases.map { keys.key(for: $0).map(String.init) ?? "" }.joined()
        #expect(letters == "vrfolatbsnphc")
        #expect(EditorTool.forKey("r", keys: keys) == .rectangle)
        #expect(EditorTool.forKey("C", keys: keys) == .crop)
        #expect(EditorTool.forKey("z", keys: keys) == nil)
    }

    @Test func aFreeLetterReplacesTheDefault() {
        var keys = AnnotateToolKeys()
        #expect(keys.set("x", for: .rectangle) == nil)
        #expect(keys.key(for: .rectangle) == "x")
        #expect(EditorTool.forKey("x", keys: keys) == .rectangle)
        #expect(EditorTool.forKey("r", keys: keys) == nil)
    }

    @Test func aLetterAnotherToolUsesIsRefused() {
        var keys = AnnotateToolKeys()
        #expect(keys.set("A", for: .rectangle) == .taken(by: .tool(.arrow)))
        #expect(keys.key(for: .rectangle) == "r")
    }

    @Test func sizeKeysAndNonLettersAreRefused() {
        var keys = AnnotateToolKeys()
        for input in ["1", "6", "[", "]"] {
            #expect(keys.set(input, for: .pen) == .reserved)
        }
        for input in ["", " ", "ab", "7", "é"] {
            #expect(keys.set(input, for: .pen) == .notALetter)
        }
        #expect(keys == AnnotateToolKeys())
    }

    @Test func aFreedLetterCanBeTakenAndADefaultStoresNothing() {
        var keys = AnnotateToolKeys()
        #expect(keys.set("x", for: .rectangle) == nil)
        #expect(keys.set("r", for: .select) == nil) // free now
        #expect(keys.key(for: .select) == "r")
        #expect(keys.set("v", for: .select) == nil)
        #expect(keys.letters["select"] == nil) // back to its default: nothing stored
    }

    @Test func theDecoderIsTolerant() throws {
        let json = #"{"letters":{"select":"q","bogus":"z","pen":"toolong"},"later":1}"#
        let decoded = try JSONDecoder().decode(AnnotateToolKeys.self, from: Data(json.utf8))
        #expect(decoded.key(for: .select) == "q")
        #expect(decoded.key(for: .pen) == "p")
        #expect(decoded.key(for: .highlighter) == "h")
        #expect(try JSONDecoder().decode(AnnotateToolKeys.self, from: Data("{}".utf8)) == AnnotateToolKeys())
        #expect(try JSONDecoder().decode(AnnotateToolKeys.self, from: Data(#"{"letters":5}"#.utf8)) == AnnotateToolKeys())
    }

    @Test func conflictingStoredLettersNeverGiveTwoToolsOneKey() {
        // Written by hand: select takes rectangle's letter without rectangle moving.
        let keys = AnnotateToolKeys(letters: ["select": "r"])
        #expect(keys.key(for: .select) == "r")
        #expect(keys.key(for: .rectangle) == nil)
        #expect(EditorTool.forKey("r", keys: keys) == .select)
    }

    @Test func twoToolsStoredWithOneLetterGiveItToTheEarlierTool() {
        let keys = AnnotateToolKeys(letters: ["rectangle": "x", "arrow": "x"])
        #expect(keys.key(for: .rectangle) == "x")
        #expect(keys.key(for: .arrow) == "a") // the later tool falls back to its default, which is free
        #expect(EditorTool.forKey("x", keys: keys) == .rectangle)

        // The default is taken as well: no letter, and still no shared key.
        let taken = AnnotateToolKeys(letters: ["rectangle": "a", "arrow": "a"])
        #expect(taken.key(for: .rectangle) == "a")
        #expect(taken.key(for: .arrow) == nil)
        let letters = Array(taken.resolved.values)
        #expect(Set(letters).count == letters.count)
    }

    @Test func everySizeKeyIsRefusedAndTiedToTheSizeLevels() {
        var keys = AnnotateToolKeys()
        for input in "123456[]" {
            #expect(keys.set(String(input), for: .pen) == .reserved)
        }
        #expect(keys == AnnotateToolKeys())
        #expect(AnnotateToolKeys.reserved == Set(ToolSizes.levels.map { Character(String($0)) } + ["[", "]"]))
    }

    @Test func aToolsOwnLetterIsNoConflict() {
        var keys = AnnotateToolKeys()
        #expect(keys.problem(with: "r", for: .rectangle) == nil)
        #expect(keys.problem(with: "R", for: .rectangle) == nil)
        #expect(keys.set("r", for: .rectangle) == nil)
        #expect(keys.letters.isEmpty)
        #expect(keys.set("x", for: .rectangle) == nil)
        #expect(keys.problem(with: "X", for: .rectangle) == nil)
    }

    @Test func anUppercaseLetterIsStoredLowercase() {
        var keys = AnnotateToolKeys()
        #expect(keys.set("X", for: .rectangle) == nil)
        #expect(keys.letters == ["rectangle": "x"])
    }

    @Test func aBadEntryDoesNotDropItsNeighbours() throws {
        let json = #"{"letters":{"select":"q","pen":5,"text":null,"arrow":["x"],"counter":"m"}}"#
        let decoded = try JSONDecoder().decode(AnnotateToolKeys.self, from: Data(json.utf8))
        #expect(decoded.key(for: .select) == "q")
        #expect(decoded.key(for: .counter) == "m")
        #expect(decoded.key(for: .pen) == "p") // a number is no letter: the default
        #expect(decoded.key(for: .text) == "t")
        #expect(decoded.key(for: .arrow) == "a")
    }

    @Test func onlyTheLettersAToZCountAsLetters() {
        var keys = AnnotateToolKeys()
        // A Kelvin sign lowercases to "k", a ligature and the letters below are letters of other alphabets.
        for input in ["\u{212A}", "ﬁ", "é", "ß", "İ", "ａ", "e\u{301}", "Ω"] {
            #expect(keys.set(input, for: .pen) == .notALetter, "\(input.unicodeScalars.map(\.value))")
        }
        #expect(keys == AnnotateToolKeys())
        // A stored one is ignored as well.
        #expect(AnnotateToolKeys(letters: ["pen": "\u{212A}"]).key(for: .pen) == "p")
        #expect(keys.set("Z", for: .pen) == nil)
        #expect(keys.key(for: .pen) == "z")
    }

    // MARK: The background panel's letter

    @Test func theBackgroundPanelHasLetterG() {
        let keys = AnnotateToolKeys()
        #expect(keys.key(for: .backgroundPanel) == "g")
        #expect(keys.target(for: "g") == .backgroundPanel)
        #expect(keys.target(for: "G") == .backgroundPanel)
        #expect(keys.target(for: "r") == .tool(.rectangle))
        let panel = AnnotateKeyTarget.backgroundPanel
        #expect(panel.id == "background")
        #expect(panel.title == "Background")
        #expect(panel.symbol == "photo.artframe")
        #expect(panel.defaultKey == "g")
        #expect(AnnotateKeyTarget.tool(.crop).id == "crop")
        #expect(AnnotateKeyTarget.tool(.crop).title == EditorTool.crop.title)
        #expect(AnnotateKeyTarget.tool(.crop).symbol == EditorTool.crop.symbol)
        #expect(AnnotateKeyTarget.tool(.crop).defaultKey == "c")
        // The tools in their order, then the panel; every target has a letter by default, no two the same.
        #expect(AnnotateKeyTarget.allCases == EditorTool.allCases.map { .tool($0) } + [.backgroundPanel])
        #expect(Set(keys.resolved.keys) == Set(AnnotateKeyTarget.allCases))
        #expect(Set(keys.resolved.values).count == AnnotateKeyTarget.allCases.count)
    }

    @Test func gConflictsLikeAToolLetter() {
        var keys = AnnotateToolKeys()
        #expect(keys.problem(with: "g", for: .rectangle) == .taken(by: .backgroundPanel))
        #expect(keys.set("G", for: .rectangle) == .taken(by: .backgroundPanel))
        #expect(keys.key(for: .rectangle) == "r")
        // The panel's letter follows the tools' rules too.
        #expect(keys.set("r", for: .backgroundPanel) == .taken(by: .tool(.rectangle)))
        #expect(keys.set("1", for: .backgroundPanel) == .reserved)
        #expect(keys.set("é", for: .backgroundPanel) == .notALetter)
        #expect(keys == AnnotateToolKeys())
        // Moved to a free letter, it is stored under "background"; set back to G, nothing is stored.
        #expect(keys.set("x", for: .backgroundPanel) == nil)
        #expect(keys.letters == ["background": "x"])
        #expect(keys.set("g", for: .rectangle) == nil) // free now
        #expect(keys.key(for: .rectangle) == "g")
        #expect(keys.set("r", for: .rectangle) == nil)
        #expect(keys.set("g", for: .backgroundPanel) == nil)
        #expect(keys.letters.isEmpty)
    }

    @Test func aStoredBackgroundLetterWins() throws {
        // A stored letter wins over a tool's default, as a tool's does.
        let keys = try JSONDecoder().decode(AnnotateToolKeys.self, from: Data(#"{"letters":{"background":"r"}}"#.utf8))
        #expect(keys.key(for: .backgroundPanel) == "r")
        #expect(keys.key(for: .rectangle) == nil)
        #expect(keys.target(for: "r") == .backgroundPanel)
        #expect(keys.target(for: "g") == nil)
        // A tool stored with G takes it from the panel's default.
        let taken = AnnotateToolKeys(letters: ["pen": "g"])
        #expect(taken.key(for: .pen) == "g")
        #expect(taken.key(for: .backgroundPanel) == nil)
        #expect(taken.target(for: "g") == .tool(.pen))
    }

    @Test func toolForKeyIsNilForThePanelsLetter() {
        let keys = AnnotateToolKeys()
        #expect(keys.tool(for: "g") == nil)
        #expect(keys.tool(for: "G") == nil)
        #expect(EditorTool.forKey("g", keys: keys) == nil)
        #expect(keys.tool(for: "c") == .crop)
    }
}

@MainActor
final class ToolKeysPrefsTests {
    let throwaway = ThrowawayDefaults("toolkeys")
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = throwaway.defaults
        prefs = Preferences(defaults: defaults)
    }

    @Test func toolKeysPersist() {
        #expect(prefs[Prefs.annotateToolKeys] == AnnotateToolKeys())
        var keys = prefs[Prefs.annotateToolKeys]
        keys.set("x", for: .rectangle)
        prefs[Prefs.annotateToolKeys] = keys
        #expect(Preferences(defaults: defaults)[Prefs.annotateToolKeys].key(for: .rectangle) == "x")
    }
}
