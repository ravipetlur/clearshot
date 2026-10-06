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

    @Test func deniedByTheUserPointsToLoginItems() {
        let message = LoginItemFeedback.message(for: error(kSMErrorLaunchDeniedByUser))
        #expect(message?.contains("Login Items") == true)
    }

    @Test func anyOtherErrorStillSaysWhatToDo() {
        let message = LoginItemFeedback.message(for: error(kSMErrorInternalFailure))
        #expect(message?.contains("Login Items") == true)
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
