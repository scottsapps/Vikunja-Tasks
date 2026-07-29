import Foundation

struct VeyrnAccount: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
}

/// On-disk shape for accounts created before Phase 2 (tokens embedded in the
/// JSON). `token` is optional so decoding never fails outright on an array
/// that mixes pre- and post-migration entries, or has none at all.
private struct LegacyAccountWithToken: Codable {
    let id: UUID
    var name: String
    var host: String
    var token: String?
}

enum VikunjaConfig {
    static let appGroupSuite = "group.net.angstreich.VikunjaWidgetApp"
    static let vikunjaCloudHost = "https://app.vikunja.cloud"
    static let maxAccounts = 5
    static let maxAccountNameLength = 10

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupSuite) }

    private static let accountsKey = "vikunja_accounts_v1"
    private static let activeAccountIdKey = "vikunja_active_account_id"
    private static let tokensMigratedKey = "vikunja_tokens_migrated_v1"

    enum AccountError: Error {
        case limitReached
        case duplicateName
    }

    // MARK: - Connection (host mirrors the active account; the token lives in the Keychain)

    static var host: String {
        defaults?.string(forKey: "vikunja_host") ?? ""
    }

    static var baseURL: String {
        let h = host
        let trimmed = h.hasSuffix("/") ? String(h.dropLast()) : h
        return "\(trimmed)/api/v1"
    }

    #if os(watchOS)
    /// The Watch has no accounts UI of its own — it only ever mirrors
    /// whatever account is active on the phone, so one fixed Keychain slot
    /// is enough; there's no per-account list to key against locally.
    static let watchTokenAccountId = UUID(uuidString: "5A17C500-0000-4000-8000-000000000001")!
    #endif

    // In-memory cache so VikunjaAPI's per-request (and per-project fan-out)
    // reads don't each hit the Keychain. Keyed by account id, so switching
    // accounts naturally invalidates it; edits/deletes invalidate explicitly
    // via `invalidateTokenCache()`.
    ///
    /// Lock-protected: `apiToken` is called from the concurrent per-project
    /// fan-out in `fetchAllUndoneTasks`, and `cachedTokenIfAvailable` is read
    /// by `DiagnosticLog.sanitize(_:)` on whatever thread emitted a log line —
    /// so reads and writes genuinely overlap. Unsynchronized access to a
    /// stored `String` from two threads can over-release it and crash. Never
    /// hold this lock across a Keychain call or anything that can log.
    private static var cachedToken: (accountId: UUID, value: String)?
    private static let cachedTokenLock = NSLock()

    private static func readCachedToken(for id: UUID) -> String? {
        cachedTokenLock.lock()
        defer { cachedTokenLock.unlock() }
        guard let cached = cachedToken, cached.accountId == id else { return nil }
        return cached.value
    }

    private static func storeCachedToken(_ value: String, for id: UUID) {
        cachedTokenLock.lock()
        cachedToken = (id, value)
        cachedTokenLock.unlock()
    }

    static var apiToken: String {
        ensureMigrated()
        #if os(watchOS)
        let id = watchTokenAccountId
        #else
        guard let id = activeAccount?.id else { return "" }
        #endif
        if let cached = readCachedToken(for: id) {
            return cached
        }
        // Deliberately outside the lock — `TokenStore.token(for:)` logs on a
        // failed read, and logging re-enters `readCachedToken` via sanitize.
        let token = TokenStore.token(for: id) ?? ""
        storeCachedToken(token, for: id)
        return token
    }

    static func invalidateTokenCache() {
        cachedTokenLock.lock()
        cachedToken = nil
        cachedTokenLock.unlock()
    }

    /// Peek at the in-memory token cache **without** ever touching the
    /// Keychain. `DiagnosticLog.sanitize(_:)` uses this (never `apiToken`) —
    /// `TokenStore.token(for:)` itself logs on a failed read, and that log
    /// line passes through `sanitize`, which would otherwise call `apiToken`,
    /// which calls `TokenStore.token(for:)` again: an unbounded recursion
    /// triggered by nothing more than a single bad Keychain read (confirmed
    /// by a real crash in the simulator — hundreds of re-entrant
    /// `SecItemCopyMatching` calls in under a second before the process died).
    static var cachedTokenIfAvailable: String? {
        #if os(watchOS)
        let id = watchTokenAccountId
        #else
        guard let id = activeAccountId else { return nil }
        #endif
        return readCachedToken(for: id)
    }

    static var isConfigured: Bool {
        !host.isEmpty && !apiToken.isEmpty
    }

    // MARK: - Accounts

    static var accounts: [VeyrnAccount] {
        ensureMigrated()
        return loadAccounts()
    }

    static var activeAccountId: UUID? {
        guard let str = defaults?.string(forKey: activeAccountIdKey) else { return nil }
        return UUID(uuidString: str)
    }

    static var activeAccount: VeyrnAccount? {
        ensureMigrated()
        let accts = loadAccounts()
        if let id = activeAccountId, let match = accts.first(where: { $0.id == id }) {
            return match
        }
        return accts.first
    }

    static func addAccount(_ account: VeyrnAccount, token: String) throws {
        var accts = loadAccounts()
        guard accts.count < maxAccounts else { throw AccountError.limitReached }
        guard !accts.contains(where: { $0.name.caseInsensitiveCompare(account.name) == .orderedSame }) else {
            throw AccountError.duplicateName
        }
        accts.append(account)
        persist(accts)
        TokenStore.setToken(token, for: account.id)
        DiagnosticLog.info("account added (now \(accts.count))")
    }

    static func updateAccount(_ account: VeyrnAccount, token: String) throws {
        var accts = loadAccounts()
        guard let index = accts.firstIndex(where: { $0.id == account.id }) else { return }
        guard !accts.contains(where: {
            $0.id != account.id && $0.name.caseInsensitiveCompare(account.name) == .orderedSame
        }) else {
            throw AccountError.duplicateName
        }
        accts[index] = account
        persist(accts)
        TokenStore.setToken(token, for: account.id)
        invalidateTokenCache()
        if activeAccountId == account.id {
            syncActiveMirror()
        }
    }

    /// Removes the account and reassigns the active account if it was the one deleted.
    /// Does not touch per-account outbox/widget-cache/reminder state — that's app-layer
    /// orchestration the caller (TaskStore) is responsible for.
    static func deleteAccount(id: UUID) {
        var accts = loadAccounts()
        accts.removeAll { $0.id == id }
        let wasActive = activeAccountId == id
        persist(accts)

        TokenStore.deleteToken(for: id)
        UserDefaults.standard.removeObject(forKey: "vikunja.outbox.v1.\(id.uuidString)")
        UserDefaults.standard.removeObject(forKey: "vikunja.outbox.placeholderCounter.v1.\(id.uuidString)")
        DiagnosticLog.info("account deleted (now \(accts.count))")

        guard wasActive else { return }
        if let first = accts.first {
            setActive(id: first.id)
        } else {
            defaults?.removeObject(forKey: activeAccountIdKey)
            syncActiveMirror()
        }
    }

    static func setActive(id: UUID) {
        defaults?.set(id.uuidString, forKey: activeAccountIdKey)
        syncActiveMirror()
    }

    /// Reads the Keychain-stored token for a specific account — used by the
    /// account editor to prefill an existing token. Not cached: this is a
    /// cold, UI-driven read, not the hot per-request path `apiToken` covers.
    static func token(for accountId: UUID) -> String {
        TokenStore.token(for: accountId) ?? ""
    }

    private static func loadAccounts() -> [VeyrnAccount] {
        guard let data = defaults?.data(forKey: accountsKey),
              let decoded = try? JSONDecoder().decode([VeyrnAccount].self, from: data)
        else { return [] }
        return decoded
    }

    private static func persist(_ accounts: [VeyrnAccount]) {
        defaults?.set(try? JSONEncoder().encode(accounts), forKey: accountsKey)
    }

    private static func syncActiveMirror() {
        let accts = loadAccounts()
        let active: VeyrnAccount?
        if let id = activeAccountId {
            active = accts.first { $0.id == id }
        } else {
            active = accts.first
        }
        if let active {
            defaults?.set(active.host, forKey: "vikunja_host")
        } else {
            defaults?.removeObject(forKey: "vikunja_host")
        }
        // The token no longer mirrors here — overwrite (not just remove) any
        // plaintext value left over from before Phase 2 so it doesn't linger
        // in the App Group plist or its backups.
        defaults?.set("", forKey: "vikunja_api_token")
        invalidateTokenCache()
    }

    // MARK: - Migration (idempotent, safe to run in any process)

    private static func ensureMigrated() {
        migrateAccountsIfNeeded()
        migrateTokensToKeychainIfNeeded()
    }

    /// 2.7.x → Phase 1: a legacy host+token mirror with no accounts array yet
    /// becomes a single account. The token goes straight to the Keychain —
    /// never embedded in the JSON in the first place.
    private static func migrateAccountsIfNeeded() {
        guard defaults?.data(forKey: accountsKey) == nil else { return }
        let legacyHost = defaults?.string(forKey: "vikunja_host") ?? ""
        let legacyToken = defaults?.string(forKey: "vikunja_api_token") ?? ""
        if !legacyHost.isEmpty && !legacyToken.isEmpty {
            let account = VeyrnAccount(
                id: UUID(),
                name: accountName(fromHost: legacyHost),
                host: legacyHost
            )
            persist([account])
            TokenStore.setToken(legacyToken, for: account.id)
            setActive(id: account.id)
            DiagnosticLog.info("migrated legacy account")
        } else {
            persist([])
        }
    }

    /// Phase 1 → Phase 2: accounts already existed with tokens embedded in
    /// the JSON. Moves each into the Keychain and rewrites the JSON without
    /// them. Gated by its own flag since `migrateAccountsIfNeeded()`'s "does
    /// the accounts key exist" check can't distinguish the old account shape
    /// from the new one.
    private static func migrateTokensToKeychainIfNeeded() {
        guard defaults?.bool(forKey: tokensMigratedKey) != true else { return }
        defer { defaults?.set(true, forKey: tokensMigratedKey) }

        guard let data = defaults?.data(forKey: accountsKey),
              let legacy = try? JSONDecoder().decode([LegacyAccountWithToken].self, from: data)
        else { return }

        var rewritten: [VeyrnAccount] = []
        var movedAny = false
        for entry in legacy {
            if let token = entry.token, !token.isEmpty {
                TokenStore.setToken(token, for: entry.id)
                movedAny = true
            }
            rewritten.append(VeyrnAccount(id: entry.id, name: entry.name, host: entry.host))
        }
        if movedAny {
            persist(rewritten)
            DiagnosticLog.info("migrated token to keychain")
        }
    }

    private static func accountName(fromHost host: String) -> String {
        if host == vikunjaCloudHost { return "Cloud" }
        let hostname = URL(string: host)?.host ?? URL(string: "https://" + host)?.host
        guard let hostname, let label = hostname.split(separator: ".").first else {
            return "Account 1"
        }
        return String(label.prefix(maxAccountNameLength))
    }

    /// Keychain items survive app deletion. Call once at launch: on the
    /// phone/Mac, no accounts at all but a lingering item means residue from
    /// a previous install; on the Watch (a single fixed slot, not the
    /// accounts array) the equivalent signal is an empty host mirror.
    static func cleanupOrphanedKeychainItemsIfNeeded() {
        #if os(watchOS)
        guard host.isEmpty else { return }
        TokenStore.deleteToken(for: watchTokenAccountId)
        #else
        guard accounts.isEmpty else { return }
        let count = TokenStore.deleteAll()
        if count > 0 {
            DiagnosticLog.info("cleaned \(count) orphaned keychain items")
        }
        #endif
    }

    // MARK: - Font size

    static var fontSizeOffset: Int {
        UserDefaults.standard.integer(forKey: "vikunja_font_size_offset")
    }

    // MARK: - Telemetry opt-in

    static var telemetryOptIn: Bool {
        UserDefaults.standard.object(forKey: "vikunja_telemetry_opt_in") as? Bool ?? true
    }

    #if os(macOS)
    static func registerHotkeyDefaults() {
        UserDefaults.standard.register(defaults: [
            "vikunja_hotkey_keycode": 49,    // kVK_Space
            "vikunja_hotkey_modifiers": 4096  // controlKey
        ])
    }

    static var quickAddKeyCode: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: "vikunja_hotkey_keycode")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "vikunja_hotkey_keycode") }
    }

    static var quickAddModifiers: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: "vikunja_hotkey_modifiers")) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "vikunja_hotkey_modifiers") }
    }
    #endif
}
