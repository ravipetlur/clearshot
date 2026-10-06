/// Tells delayed work whether it still belongs to the latest request. Each `next()` starts a new
/// generation; work captured with an older one should do nothing.
public struct GenerationCounter: Sendable {
    public private(set) var current = 0

    public init() {}

    public mutating func next() -> Int {
        current &+= 1
        return current
    }

    public func isCurrent(_ generation: Int) -> Bool {
        generation == current
    }
}
