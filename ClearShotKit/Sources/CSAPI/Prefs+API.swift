import CSCore

/// The URL scheme API's setting. Settings › Advanced shows "Allow URL scheme API"; the first command from another app
/// asks once. Neither grants anything by itself: the consent is the grant in a `ConsentStore` (the Keychain), and
/// these, which any process running as the user can write, can only take it away (`URLConsent.decide`). They live here,
/// not in CSCore, so Reset All Warning Dialogs (`Prefs.allWarningDialogs`, CSRecording) can't name them: the consent is
/// a permission, not a "Don't ask again".
public extension Prefs {
    /// Off drops every command from another app; on runs them once the grant is stored.
    static let allowURLSchemeAPI = PrefKey("allowURLSchemeAPI", default: true)
    /// The person has answered the prompt. Only a flag: a missing grant asks again, whatever it says.
    static let didAskAboutURLSchemeAPI = PrefKey("didAskAboutURLSchemeAPI", default: false)
}
