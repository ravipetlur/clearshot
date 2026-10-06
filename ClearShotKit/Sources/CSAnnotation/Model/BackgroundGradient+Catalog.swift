import Foundation

extension BackgroundGradient {
    /// The gradients the Background tool offers, in the panel's order: 20 original designs, each with its stops evenly
    /// spaced from 0 to 1.
    public static let catalog: [BackgroundGradient] = catalogEntries.map(\.gradient)

    /// The first catalog gradient, the standard style's fill and what a missing picture falls back to.
    public static var standard: BackgroundGradient {
        catalog[0]
    }

    /// The catalog gradient's name, found by its id, or "Gradient" for any other.
    public var title: String {
        id.flatMap { Self.catalogNames[$0] } ?? "Gradient"
    }

    private struct CatalogEntry: Sendable {
        let id: String
        let name: String
        let gradient: BackgroundGradient

        init(_ id: String, _ name: String, _ kind: Kind, _ colors: String...) {
            self.id = id
            self.name = name
            let last = Double(colors.count - 1)
            let stops = colors.enumerated().map { index, hex in Stop(color: RGBAColor(hex: hex)!, location: Double(index) / last) }
            gradient = BackgroundGradient(id: id, kind: kind, stops: stops)
        }
    }

    private static let catalogEntries: [CatalogEntry] = [
        CatalogEntry("coral", "Coral", .linear(angle: 45), "#FF8A7A", "#FF5E8A"),
        CatalogEntry("lagoon", "Lagoon", .linear(angle: 45), "#1FC8F0", "#2A5BE8"),
        CatalogEntry("meadow", "Meadow", .linear(angle: 45), "#B3E26A", "#4FA83A"),
        CatalogEntry("dusk", "Dusk", .linear(angle: 45), "#6A2BD0", "#2F7BF5"),
        CatalogEntry("ember", "Ember", .linear(angle: 45), "#F2491C", "#F7C631"),
        CatalogEntry("glacier", "Glacier", .linear(angle: 90), "#E6FAFC", "#7FDCE8", "#2DB8CF"),
        CatalogEntry("orchid", "Orchid", .linear(angle: 45), "#D33CF5", "#8A3BEB"),
        CatalogEntry("citrus", "Citrus", .linear(angle: 45), "#F8D86A", "#F99A7C"),
        CatalogEntry("slate", "Slate", .linear(angle: 90), "#4E5B6A", "#262E38"),
        CatalogEntry("mint", "Mint", .linear(angle: 45), "#DCF98A", "#8EDFA4"),
        CatalogEntry("aurora", "Aurora", .linear(angle: 30), "#12EFA2", "#14CFEA", "#7A63F6"),
        CatalogEntry("peach", "Peach", .linear(angle: 45), "#FFEBD6", "#F9AE96"),
        CatalogEntry("midnight", "Midnight", .linear(angle: 45), "#10232B", "#22404A", "#2E5770"),
        CatalogEntry("bloom", "Bloom", .linear(angle: 45), "#F7CBF0", "#F06EF0"),
        CatalogEntry("skyglow", "Sky glow", .radial, "#A5D4FF", "#3D7BF0"),
        CatalogEntry("sunset", "Sunset", .linear(angle: 90), "#FF5A3C", "#F2A024", "#FFD877"),
        CatalogEntry("lavender", "Lavender", .linear(angle: 45), "#E4CBFA", "#92C6F8"),
        CatalogEntry("forest", "Forest", .linear(angle: 45), "#18505C", "#74B07D"),
        CatalogEntry("candy", "Candy", .radial, "#FCCDEB", "#A9C0EF"),
        CatalogEntry("graphite", "Graphite", .radial, "#5C5C5C", "#1E1E1E"),
    ]

    /// Names by id.
    private static let catalogNames: [String: String] = Dictionary(catalogEntries.map { ($0.id, $0.name) },
                                                                   uniquingKeysWith: { first, _ in first })
}
