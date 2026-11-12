import Foundation
import ServiceManagement
import Testing
@testable import CSCore

struct LoginItemFeedbackTests {
    func error(_ code: Int) -> NSError {
        NSError(domain: "SMAppServiceErrorDomain", code: code)
    }

    @Test func alreadyInTheRequestedStateIsNotAnError() {
        // Turning off an item that isn't registered used to show "The operation couldn't be completed".
        #expect(LoginItemFeedback.message(for: error(kSMErrorAlreadyRegistered)) == nil)
        #expect(LoginItemFeedback.message(for: error(kSMErrorJobNotFound)) == nil)
    }

    /// Denied by the user, or any other error: the message still says where to go.
    @Test(arguments: [kSMErrorLaunchDeniedByUser, kSMErrorInternalFailure])
    func aRealErrorPointsToLoginItems(code: Int) {
        #expect(LoginItemFeedback.message(for: error(code))?.contains("Login Items") == true)
    }

    @Test func pendingApprovalCountsAsOnButNeedsAction() {
        #expect(LoginItemState(.requiresApproval) == .requiresApproval)
        #expect(LoginItemState(.requiresApproval).isOn)
        #expect(LoginItemState(.enabled) == .enabled)
        #expect(LoginItemState(.notRegistered) == .disabled)
        #expect(LoginItemState(.notFound) == .disabled)
        #expect(!LoginItemState(.notRegistered).isOn)
    }
}
