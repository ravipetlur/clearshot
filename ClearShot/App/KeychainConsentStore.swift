import CSAPI
import CSCore
import Foundation
import Security

/// The URL scheme API's consent: a generic-password item in the login keychain that ClearShot creates with the default
/// access control, which lets only ClearShot's code signature read it without asking. Writing ClearShot's defaults
/// can't grant the consent; deleting this item, or turning the setting off, takes it away.
///
/// What it stops, measured (probes in throwaway file keychains):
/// - `defaults write`: the defaults never grant anything (`URLConsent.decide`).
/// - Not a process running as the user that writes this item itself. An item created under this name by another
///   process and trusting ClearShot (`security add-generic-password … -T <app>`, `-A`, or a tool's `SecAccessCreate`)
///   reads silently, status 0, just like ClearShot's own. Nothing tells them apart: no item, ClearShot's own included,
///   carries a partition ID, and an untrusted process can even overwrite this item's data silently (it can't delete
///   it). The data-protection keychain, which would bind the item to ClearShot's team, refuses this unprovisioned app
///   (−34018, a required entitlement is missing). That residual risk remains.
///
/// Reads and deletes run with the keychain's dialogs off (`KeychainDialogs.off`): with only an `LAContext` that
/// disallows interaction, or `kSecUseAuthenticationUIFail`, reading an item that doesn't trust ClearShot waited on the
/// "wants to use your confidential information" dialog (killed after 15 s when measured); with them off it fails at
/// once (−25293).
final class KeychainConsentStore: ConsentStore {
    static let service = CSCore.identifier("url-consent")
    private static let account = "allow-url-scheme-api"
    /// What the item holds; anything else is no grant.
    private static let marker = Data("granted".utf8)

    private static var item: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    var isGranted: Bool {
        var query = Self.item
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = KeychainDialogs.off { SecItemCopyMatching(query as CFDictionary, &result) }
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.api.error("Couldn't read the URL consent from the keychain (\(status)); treating it as not given")
            }
            return false
        }
        return result as? Data == Self.marker
    }

    /// Replaces any item under the name with ClearShot's own, created with the default access control. The add may ask
    /// to unlock the keychain: the person has just clicked Allow or turned the switch on.
    func grant() -> Bool {
        revoke()
        var attributes = Self.item
        attributes[kSecValueData] = Self.marker
        attributes[kSecAttrLabel] = "ClearShot URL scheme API consent"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            Log.api.error("Couldn't store the URL consent in the keychain (\(status))")
            return false
        }
        return true
    }

    func revoke() {
        let query = Self.item
        let status = KeychainDialogs.off { SecItemDelete(query as CFDictionary) }
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.api.error("Couldn't remove the URL consent from the keychain (\(status))")
        }
    }
}

/// The file keychain's per-process "user interaction allowed" switch, the only one that keeps its own dialogs away
/// (measured, above; a fresh process starts with it on again).
private enum KeychainDialogs {
    /// Runs `body` with the dialogs off for this process, then puts the switch back as it was.
    static func off<Result>(_ body: () -> Result) -> Result {
        let legacy: any KeychainInteraction.Type = LegacyKeychainInteraction.self
        let wasAllowed = legacy.isAllowed
        legacy.setAllowed(false)
        defer { legacy.setAllowed(wasAllowed ?? true) }
        return body()
    }
}

/// `SecKeychain…`'s interaction switch is deprecated with no replacement for the file keychain. As with
/// `RealTimeMediaInput` (CSRecording), the deprecated functions are reached through a protocol of our own, so the build
/// stays free of warnings while the calls stay where they can be found.
private protocol KeychainInteraction {
    /// Nil when it can't be read.
    static var isAllowed: Bool? { get }
    static func setAllowed(_ allowed: Bool)
}

private enum LegacyKeychainInteraction: KeychainInteraction {
    @available(macOS, deprecated: 10.10, message: "SecKeychain's interaction switch has no replacement")
    static var isAllowed: Bool? {
        var allowed: DarwinBoolean = true
        return SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess ? allowed.boolValue : nil
    }

    @available(macOS, deprecated: 10.10, message: "SecKeychain's interaction switch has no replacement")
    static func setAllowed(_ allowed: Bool) {
        let status = SecKeychainSetUserInteractionAllowed(allowed)
        if status != errSecSuccess { Log.api.error("Couldn't switch the keychain's dialogs (\(status))") }
    }
}
