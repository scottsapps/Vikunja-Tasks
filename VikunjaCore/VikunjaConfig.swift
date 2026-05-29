import Foundation

enum VikunjaConfig {
    static let appGroupSuite = "group.net.angstreich.VikunjaWidgetApp"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroupSuite) }

    static var host: String {
        defaults?.string(forKey: "vikunja_host") ?? ""
    }

    static var apiToken: String {
        defaults?.string(forKey: "vikunja_api_token") ?? ""
    }

    static var baseURL: String {
        let h = host.isEmpty ? "" : host
        let trimmed = h.hasSuffix("/") ? String(h.dropLast()) : h
        return "\(trimmed)/api/v1"
    }

    static var isConfigured: Bool {
        !apiToken.isEmpty && !host.isEmpty
    }

    static var fontSizeOffset: Int {
        UserDefaults.standard.integer(forKey: "vikunja_font_size_offset")
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
