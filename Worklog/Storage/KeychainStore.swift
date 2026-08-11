import Foundation
import Security

/// The two Transcribe API keys. They live only in the Keychain - never in
/// settings, never in the repo, never in plaintext on disk. Settings writes
/// through this; the pipeline only reads.
enum KeychainKey: String, CaseIterable {
    case elevenLabsAPIKey = "com.worklog.elevenlabs-api-key"
    case anthropicAPIKey = "com.worklog.anthropic-api-key"
}

/// Reads and writes those keys.
///
/// This is four lines per operation on iOS, where the macOS build needed a
/// page of ACL machinery, and the difference is worth knowing about.
///
/// macOS keychain items carry an access-control list, and an item written with
/// no explicit policy trusts the creating process *by snapshot* - so every
/// rebuild changed the signature, stopped matching, and made macOS ask for the
/// login password once per stored key. The macOS build fixes that with an
/// explicit `SecAccess` naming the app's designated requirement.
///
/// None of it applies here. The iOS keychain is the data-protection keychain,
/// which has no ACLs and no partition lists: items are scoped to the app's
/// keychain access group, and the sandbox is what enforces it. No other app
/// can read these keys, there is nothing to prompt for, and there is nothing
/// to re-adopt after a rebuild. The one thing worth setting deliberately is
/// the accessibility class, below.
enum KeychainStore {
    /// `ThisDeviceOnly` so the keys never sync to iCloud Keychain or ride
    /// along in an encrypted backup restored onto a different phone. They are
    /// this device's credentials for the user's own accounts; silently
    /// copying them elsewhere is not something the app should decide.
    ///
    /// `AfterFirstUnlock` rather than `WhenUnlocked` because transcription
    /// runs while the phone is in a pocket - a clip created and uploaded with
    /// the screen locked has to be able to read the key.
    private static let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    static func read(_ key: KeychainKey) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns `false` on any Keychain failure so callers can surface a real
    /// error instead of silently claiming success - Settings' API Keys section
    /// reads this return value.
    @discardableResult
    static func write(_ value: String, for key: KeychainKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Delete-then-add rather than update: the accessibility class is set
        // at creation, so an update would leave an existing item on whatever
        // class it was first written with.
        SecItemDelete(baseQuery(for: key) as CFDictionary)

        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ key: KeychainKey) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private static func baseQuery(for key: KeychainKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Worklog",
            kSecAttrAccount as String: key.rawValue,
        ]
    }
}
