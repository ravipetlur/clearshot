import Testing
import CSUpdate

/// What a code-signature check's OSStatus says about the app: passed, signed by someone else, or not validly signed.
struct SignatureStatusTests {
    @Test func successPasses() {
        #expect(SignatureStatus.failure(forStatus: 0) == nil)
    }

    /// `errSecCSReqFailed`: the code is signed, but doesn't satisfy the requirement (another team, or ad-hoc).
    @Test func aFailedRequirementIsAnotherSigner() {
        #expect(SignatureStatus.requirementFailed == -67050)
        #expect(SignatureStatus.failure(forStatus: -67050) == .signerMismatch)
    }

    @Test(arguments: [
        -67061,  // errSecCSSignatureFailed: modified
        -67054,  // errSecCSBadResource: a sealed resource is missing or invalid
        -67062,  // errSecCSUnsigned
        -67022,  // errSecCSUnsignedNestedCode
        -67030, -67001, -1, 1, 2, Int32.max, Int32.min,
    ] as [Int32])
    func anyOtherFailureIsAnInvalidSignature(status: Int32) {
        #expect(SignatureStatus.failure(forStatus: status) == .signatureInvalid)
    }
}
