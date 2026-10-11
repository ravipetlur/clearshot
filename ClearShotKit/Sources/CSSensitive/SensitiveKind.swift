/// What a finding is. The four kinds are the four switches of Settings, so a scan can be limited to the ones the owner
/// left on.
public enum SensitiveKind: Sendable, Equatable, Hashable, CaseIterable {
    /// An email address or a phone number.
    case contact
    /// A well-known key or token format, a private-key block, a key file's name, or the value of a labelled secret.
    case keyOrToken
    /// A payment card number: 13 to 19 digits that pass the Luhn check, or are written in a card's own grouping, or follow a
    /// card label.
    case card
    /// An IPv4 or IPv6 address that isn't a loopback, documentation or broadcast address.
    case ipAddress

    /// The kind as Settings names it, and as the badge's tooltip counts it.
    public var title: String {
        switch self {
        case .contact: "Contact details"
        case .keyOrToken: "Keys and tokens"
        case .card: "Card numbers"
        case .ipAddress: "IP addresses"
        }
    }

    /// The switch that turns this kind on and off: the kind as a member of the set a scan is asked for.
    public var option: SensitiveKinds {
        switch self {
        case .contact: .contact
        case .keyOrToken: .keysAndTokens
        case .card: .cards
        case .ipAddress: .ipAddresses
        }
    }

    /// One line under the kind's switch in Settings, saying what it covers.
    public var explanation: String {
        switch self {
        case .contact: "Email addresses and phone numbers."
        case .keyOrToken: "API keys, access tokens, passwords and private keys."
        case .card: "Payment card numbers."
        case .ipAddress: "IPv4 and IPv6 addresses, except localhost and example ranges."
        }
    }

    /// How specific the kind is. Where findings overlap, the most specific one names the merged finding: a key or token
    /// says more than a card number, which says more than an address, which says more than a digit run a phone-number
    /// detector liked.
    var specificity: Int {
        switch self {
        case .keyOrToken: 3
        case .card: 2
        case .ipAddress: 1
        case .contact: 0
        }
    }
}

/// Which kinds of finding a scan looks for.
public struct SensitiveKinds: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Email addresses and phone numbers.
    public static let contact = SensitiveKinds(rawValue: 1 << 0)
    public static let keysAndTokens = SensitiveKinds(rawValue: 1 << 1)
    public static let cards = SensitiveKinds(rawValue: 1 << 2)
    public static let ipAddresses = SensitiveKinds(rawValue: 1 << 3)
    public static let all: SensitiveKinds = [.contact, .keysAndTokens, .cards, .ipAddresses]
}

/// A span of a line of text that looks sensitive. The range indexes the line it was found in.
public struct TextFinding: Equatable, Sendable {
    public let kind: SensitiveKind
    public let range: Range<String.Index>

    public init(kind: SensitiveKind, range: Range<String.Index>) {
        self.kind = kind
        self.range = range
    }
}
