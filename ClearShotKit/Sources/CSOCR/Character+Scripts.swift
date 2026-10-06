/// The scripts text recognition treats specially.
extension Character {
    /// Han, Hiragana, Katakana, Hangul, or CJK punctuation (including the full-width forms). The assembler joins two
    /// such lines without a space unless either side is Hangul, and ownership at a tile cut takes each such character as
    /// a word of its own.
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x11FF, // Hangul Jamo
             0x2E80...0x2FDF, // CJK radicals, Kangxi radicals
             0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x3130...0x318F, // Hangul compatibility Jamo
             0x31F0...0x31FF, // Katakana phonetic extensions
             0x3400...0x4DBF, // CJK unified ideographs extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xA960...0xA97F, // Hangul Jamo extended A
             0xAC00...0xD7FF, // Hangul syllables, Jamo extended B
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFE30...0xFE4F, // CJK compatibility forms
             0xFF00...0xFFEF, // half-width and full-width forms
             0x20000...0x323AF: // CJK unified ideographs extensions B and on, compatibility supplement
            return true
        default:
            return false
        }
    }

    /// Hangul: syllables, Jamo and their compatibility and half-width forms. Korean separates words with spaces.
    var isHangul: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x1100...0x11FF, // Hangul Jamo
             0x3130...0x318F, // Hangul compatibility Jamo
             0xA960...0xA97F, // Hangul Jamo extended A
             0xAC00...0xD7FF, // Hangul syllables, Jamo extended B
             0xFFA0...0xFFDC: // half-width Hangul
            return true
        default:
            return false
        }
    }

    /// Han or Kana (Hiragana, Katakana, their punctuation): written without spaces between words, unlike Hangul.
    var isHanOrKana: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x2FDF, // CJK radicals, Kangxi radicals
             0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x309F, // Hiragana
             0x30A0...0x30FF, // Katakana
             0x31F0...0x31FF, // Katakana phonetic extensions
             0x3400...0x4DBF, // CJK unified ideographs extension A
             0x4E00...0x9FFF, // CJK unified ideographs
             0xF900...0xFAFF, // CJK compatibility ideographs
             0xFF61...0xFF9F, // half-width CJK punctuation and Katakana
             0x20000...0x323AF: // CJK unified ideographs extensions B and on, compatibility supplement
            return true
        default:
            return false
        }
    }
}
