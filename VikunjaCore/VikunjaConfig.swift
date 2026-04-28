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
}
