import Foundation
import Testing
@testable import CSCore

struct PermissionTests {
    @Test func settingsLinksOpenTheRightPrivacyPane() {
        #expect(Permission.screenRecording.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(Permission.microphone.settingsURL.absoluteString.hasSuffix("?Privacy_Microphone"))
        #expect(Permission.accessibility.settingsURL.absoluteString.hasSuffix("?Privacy_Accessibility"))
    }

    @Test func thePermissionsAreTheOnesClearShotStillUses() {
        // No camera: the camera overlay was dropped.
        #expect(Permission.allCases == [.screenRecording, .microphone, .accessibility])
    }

    @Test func accessibilityIsForScrollingCapturesAutoScroll() {
        // Keystroke display and Studio Mode were dropped; auto-scroll still needs Accessibility.
        #expect(Permission.accessibility.reason == "Scrolls the page for you in scrolling captures.")
    }

    @Test func onlyScreenRecordingIsRequiredUpFront() {
        #expect(Permission.allCases.filter(\.isRequired) == [.screenRecording])
    }

    @Test func everyPermissionExplainsItself() {
        for permission in Permission.allCases {
            #expect(!permission.title.isEmpty)
            #expect(!permission.reason.isEmpty)
        }
    }
}
