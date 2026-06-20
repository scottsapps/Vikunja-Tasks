import Foundation

enum VikunjaConfig {
    static let appGroupSuite = "group.net.angstreich.VikunjaWidgetApp"
    static let vikunjaCloudHost = "https://app.vikunja.cloud"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupSuite) }

    // MARK: - Connection

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

    // MARK: - Persistence

    static func saveToken(_ token: String) {
        defaults?.set(token, forKey: "vikunja_api_token")
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
