import Foundation
import Security

/// Thin SecItem wrapper storing Vikunja API tokens in the Keychain, keyed by
/// account UUID. Shared across all six targets via the `keychain-access-groups`
/// entitlement (see the Makefile) so the app, both widget extensions, and (on
/// their own device) the Watch app and Watch widget extension can all read
/// the active account's token — no `kSecAttrAccessGroup` needed in the
/// queries below, since each target has exactly one keychain access group in
/// its entitlements and the OS resolves it automatically.
///
/// Every query sets `kSecUseDataProtectionKeychain` — see `query(account:)`.
/// That is what makes the entitlement-based sharing above actually apply on
/// macOS; without it the whole scheme silently degrades to a per-app store.
enum TokenStore {
    private static let service = "net.angstreich.VikunjaWidgetApp.token"

    private static func query(account id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            // Required on macOS, no-op on iOS/watchOS. Without it macOS uses
            // the legacy file-based keychain (login.keychain-db), where the
            // keychain-access-groups entitlement does NOT govern access —
            // reads are gated by per-item ACLs tied to the creating binary.
            // The widget extension is a different binary, so it couldn't read
            // the token, isConfigured went false, and the widget silently fell
            // back to stale cache: it kept showing the previous account's
            // tasks (including already-completed ones) while the app was fine.
            // kSecAttrAccessible is also ignored in the legacy keychain.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func token(for id: UUID) -> String? {
        var q = query(account: id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            // Never the item itself — just the raw OSStatus. This is the
            // signature of the kSecUseDataProtectionKeychain-missing bug: a
            // read that silently lands on the wrong keychain store looks
            // exactly like "no token yet" from the caller's side.
            if status != errSecSuccess {
                DiagnosticLog.error("token read failed: OSStatus \(status) (\(accountLabel(for: id)))")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func accountLabel(for id: UUID) -> String {
        if let index = VikunjaConfig.accounts.firstIndex(where: { $0.id == id }) {
            return "account #\(index + 1)"
        }
        return "account ?"
    }

    /// Accessible after first unlock — not the default (`whenUnlocked`).
    /// Widget timeline refreshes and `BackgroundRefresh` can fire before the
    /// device is first unlocked after a reboot; with the default class those
    /// refreshes would silently fail to read the token until the user
    /// unlocks the device once.
    static func setToken(_ token: String, for id: UUID) {
        guard let data = token.data(using: .utf8) else { return }
        let q = query(account: id)

        var addAttributes = q
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addAttributes as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        DiagnosticLog.info("token updated (\(accountLabel(for: id)))")
    }

    static func deleteToken(for id: UUID) {
        SecItemDelete(query(account: id) as CFDictionary)
    }

    /// Deletes every token under this service, regardless of account.
    /// Keychain items survive app deletion — used at launch when there are
    /// no accounts left but items still exist, which means they're residue
    /// from a previous install. Returns the count deleted, for logging.
    @discardableResult
    static func deleteAll() -> Int {
        let searchQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(searchQuery as CFDictionary, &result)
        let count = status == errSecSuccess ? (result as? [[String: Any]])?.count ?? 0 : 0

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        return count
    }
}
