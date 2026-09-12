//  Vendored from Calvane Widget — Widget/Model/PageState.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  PageState.swift
//  Widget
//
//  Per-widget page index (§7), stored in the App Group so the paging intent (which may run
//  in the app's process) and the timeline provider (in the extension) agree.
//
//  Stored as { page, setAt }. The provider treats page as 0 once setAt is older than 15
//  minutes, or once the day has rolled — a cursor pointing at yesterday is worse than none.
//
//  Keyed by (kind, family): with one iOS medium and one Mac large that is exactly right;
//  two widgets of the same family would page in lockstep — accepted (§7).
//

import Foundation

enum PageState {
    static var appGroup: String { VikunjaConfig.appGroupSuite }
    static let expiry: TimeInterval = 15 * 60
    static let maxPage = 1

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    private static func storageKey(_ key: String) -> String { "pageState.\(key)" }

    static func set(_ page: Int, for key: String) {
        let clamped = min(max(page, 0), maxPage)
        defaults?.set(
            ["page": clamped, "setAt": Date().timeIntervalSinceReferenceDate],
            forKey: storageKey(key)
        )
    }

    /// The effective page right now, applying the 15-minute and midnight resets (§7).
    static func currentPage(for key: String, now: Date, calendar: Calendar) -> Int {
        guard let record = defaults?.dictionary(forKey: storageKey(key)),
              let page = record["page"] as? Int, page > 0,
              let setAt = record["setAt"] as? TimeInterval
        else { return 0 }

        let setDate = Date(timeIntervalSinceReferenceDate: setAt)
        if now.timeIntervalSince(setDate) > expiry { return 0 }
        if !calendar.isDate(setDate, inSameDayAs: now) { return 0 }
        return min(page, maxPage)
    }

    /// When a non-zero page will snap back to 0, so the provider can schedule an entry that
    /// actively performs the reset (§7).
    static func snapBackDate(for key: String, calendar: Calendar) -> Date? {
        guard let record = defaults?.dictionary(forKey: storageKey(key)),
              let page = record["page"] as? Int, page > 0,
              let setAt = record["setAt"] as? TimeInterval
        else { return nil }

        let setDate = Date(timeIntervalSinceReferenceDate: setAt)
        let byExpiry = setDate.addingTimeInterval(expiry)
        let byMidnight = calendar.startOfDay(for: setDate.addingTimeInterval(86_400))
        return min(byExpiry, byMidnight)
    }
}
