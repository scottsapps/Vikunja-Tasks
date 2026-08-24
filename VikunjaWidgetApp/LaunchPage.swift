#if os(iOS)
import Foundation
import UIKit

/// Which page the app opens on — iPhone only. Anything with a permanent
/// sidebar (iPad, Mac) already has the root list on screen at all times, so
/// there is no opening page to choose there.
enum LaunchPage: String, CaseIterable, Identifiable {
    /// The root list: Inbox, Scheduled, Logbook, Projects.
    case main
    case scheduled
    case lastUsed
    case project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .main:      return "Main"
        case .scheduled: return "Scheduled"
        case .lastUsed:  return "Last Used"
        case .project:   return "Project"
        }
    }
}

extension SidebarItem {
    /// Stable string form for UserDefaults — the associated project id rules
    /// out a plain `RawRepresentable` conformance.
    var storageKey: String {
        switch self {
        case .inbox:            return "inbox"
        case .today:            return "today"
        case .logbook:          return "logbook"
        case .project(let id):  return "project:\(id)"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "inbox":   self = .inbox
        case "today":   self = .today
        case "logbook": self = .logbook
        default:
            let prefix = "project:"
            guard storageKey.hasPrefix(prefix),
                  let id = Int(storageKey.dropFirst(prefix.count)) else { return nil }
            self = .project(id)
        }
    }
}

/// The launch-page preference. `UserDefaults.standard` rather than the App
/// Group, matching the other app-only settings (font size, analytics) — no
/// extension reads this.
enum LaunchPreferences {
    static let pageKey = "vikunja_launch_page"
    static let projectKey = "vikunja_launch_project"
    static let lastUsedKey = "vikunja_last_used_page"

    /// The root list is not a `SidebarItem`, so it gets its own token in the
    /// last-used slot.
    private static let mainToken = "main"

    /// iPhone only — see `LaunchPage`. Gates both the setting and the
    /// navigation it drives, so an iPad behaves exactly as it did before the
    /// setting existed.
    static var isSupported: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    static var page: LaunchPage {
        LaunchPage(rawValue: UserDefaults.standard.string(forKey: pageKey) ?? "") ?? .main
    }

    /// The page `.project` opens on — Inbox, or one of the user's projects.
    static var launchProject: SidebarItem {
        SidebarItem(storageKey: UserDefaults.standard.string(forKey: projectKey) ?? "") ?? .inbox
    }

    /// nil = the root list, either because that's where the user was or
    /// because nothing has been recorded yet.
    static var lastUsed: SidebarItem? {
        guard let key = UserDefaults.standard.string(forKey: lastUsedKey) else { return nil }
        return SidebarItem(storageKey: key)
    }

    static func recordLastUsed(_ item: SidebarItem?) {
        UserDefaults.standard.set(item?.storageKey ?? mainToken, forKey: lastUsedKey)
    }

    /// The page to show on launch and on every return from the background,
    /// or nil for the root list.
    static var destination: SidebarItem? {
        guard isSupported else { return nil }
        switch page {
        case .main:      return nil
        case .scheduled: return .today
        case .lastUsed:  return lastUsed
        case .project:   return launchProject
        }
    }
}
#endif
