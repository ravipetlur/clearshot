/// The label inside a counter. Values below 1 show as their number in every style.
public enum CounterLabel {
    public static func text(for value: Int, style: CounterStyle) -> String {
        switch style {
        case .numbers: return String(value)
        case .roman: return value >= 1 && value < 4000 ? roman(value) : String(value)
        case .uppercase: return value >= 1 ? letters(value) : String(value)
        case .lowercase: return value >= 1 ? letters(value).lowercased() : String(value)
        }
    }

    private static func roman(_ value: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var remaining = value
        var result = ""
        for (amount, numeral) in table {
            while remaining >= amount {
                result += numeral
                remaining -= amount
            }
        }
        return result
    }

    /// A, B … Z, AA, AB … (bijective base 26).
    private static func letters(_ value: Int) -> String {
        var remaining = value
        var result = ""
        while remaining > 0 {
            remaining -= 1
            result = String(UnicodeScalar(UInt8(65 + remaining % 26))) + result
            remaining /= 26
        }
        return result
    }
}
