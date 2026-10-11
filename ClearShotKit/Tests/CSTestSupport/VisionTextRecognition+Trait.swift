import Testing

public extension Trait where Self == ConditionTrait {
    /// Skips a test that runs Vision's text recognition on a Mac where it can't run (see `VisionTextRecognition`): a hosted CI
    /// runner is a virtual Mac with no Neural Engine, and every recognition throws there.
    ///
    ///     @Test(.needsVisionTextRecognition) func …
    static var needsVisionTextRecognition: Self {
        .enabled("Vision text recognition isn't available on this Mac (a virtual Mac has no Neural Engine)") {
            await VisionTextRecognition.available
        }
    }
}
