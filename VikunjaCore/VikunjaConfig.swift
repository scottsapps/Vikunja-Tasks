import Foundation

struct VeyrnAccount: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var token: String
}

enum VikunjaConfig {
    static let appGroupSuite = "group.net.angstreich.VikunjaWidgetApp"
    static let vikunjaCloudHost = "https://app.vikunja.cloud"
    static let maxAccounts = 5
    static let maxAccountNameLength = 10

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupSuite) }

    private static let accountsKey = "vikunja_accounts_v1"
    private static let activeAccountIdKey = "vikunja_active_account_id"

    enum AccountError: Error {
        case limitReached
        case duplicateName
    }

    // MARK: - Connection (mirror of the active account — rewritten by syncActiveMirror())

    static var host: String {
        defaults?.string(forKey: "vikunja_host") ?? ""
    }

    static var baseURL: String {
        let h = host
        let trimmed = h.hasSuffix("/") ? String(h.dropLast()) : h
        return "\(trimmed)/api/v1"
    }

    static var apiToken: String {
        defaults?.string(forKey: "vikunja_api_token") ?? ""
    }

    static var isConfigured: Bool {
        !host.isEmpty && !apiToken.isEmpty
    }

    // MARK: - Accounts

    static var accounts: [VeyrnAccount] {
        migrate()
        return loadAccounts()
    }

    static var activeAccountId: UUID? {
        guard let str = defaults?.string(forKey: activeAccountIdKey) else { return nil }
        return UUID(uuidString: str)
    }

    static var activeAccount: VeyrnAccount? {
        migrate()
        let accts = loadAccounts()
        if let id = activeAccountId, let match = accts.first(where: { $0.id == id }) {
            return match
        }
        return accts.first
    }

    static func addAccount(_ account: VeyrnAccount) throws {
        var accts = loadAccounts()
        guard accts.count < maxAccounts else { throw AccountError.limitReached }
        guard !accts.contains(where: { $0.name.caseInsensitiveCompare(account.name) == .orderedSame }) else {
            throw AccountError.duplicateName
        }
        accts.append(account)
        persist(accts)
    }

    static func updateAccount(_ account: VeyrnAccount) throws {
        var accts = loadAccounts()
        guard let index = accts.firstIndex(where: { $0.id == account.id }) else { return }
        guard !accts.contains(where: {
            $0.id != account.id && $0.name.caseInsensitiveCompare(account.name) == .orderedSame
        }) else {
            throw AccountError.duplicateName
        }
        accts[index] = account
        persist(accts)
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

        UserDefaults.standard.removeObject(forKey: "vikunja.outbox.v1.\(id.uuidString)")
        UserDefaults.standard.removeObject(forKey: "vikunja.outbox.placeholderCounter.v1.\(id.uuidString)")

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
            defaults?.set(active.token, forKey: "vikunja_api_token")
        } else {
            defaults?.removeObject(forKey: "vikunja_host")
            defaults?.removeObject(forKey: "vikunja_api_token")
        }
    }

    // MARK: - Migration (idempotent, safe to run in any process)

    private static func migrate() {
        guard defaults?.data(forKey: accountsKey) == nil else { return }
        let legacyHost = defaults?.string(forKey: "vikunja_host") ?? ""
        let legacyToken = defaults?.string(forKey: "vikunja_api_token") ?? ""
        if !legacyHost.isEmpty && !legacyToken.isEmpty {
            let account = VeyrnAccount(
                id: UUID(),
                name: accountName(fromHost: legacyHost),
                host: legacyHost,
                token: legacyToken
            )
            persist([account])
            setActive(id: account.id)
        } else {
            persist([])
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
