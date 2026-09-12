//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/AgendaSampleData.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  AgendaSampleData.swift
//  VeyrnCalendar
//
//  Neutral, invented placeholder content — never the user's real calendar (§10).
//
//  The widget gallery prefers the *user's own* events (AgendaProvider.snapshot handles
//  that); this is the fallback for the cases where there is nothing real to show yet —
//  calendar access not granted, an empty horizon, or the redacted placeholder — plus the
//  in-app layout harness and the Xcode previews.
//
//  It deliberately mirrors the *shape* of a busy agenda (an all-day chip, a two-line
//  title, a long location, a declined event, a tentative event, a video call) so layout
//  tuning still has something representative to work against.
//

import Foundation

public extension AgendaSnapshot {
    /// `emptyToday` drops today's items so the harness can show the "TODAY … / No Events"
    /// state (the gallery preview keeps today rich).
    static func sample(referenceDate: Date = .now, calendar: Calendar = .current, emptyToday: Bool = false) -> AgendaSnapshot {
        let cal = calendar
        let day0 = cal.startOfDay(for: referenceDate)
        let day1 = cal.date(byAdding: .day, value: 1, to: day0)!
        let day2 = cal.date(byAdding: .day, value: 2, to: day0)!

        func at(_ day: Date, _ h: Int, _ m: Int) -> Date {
            cal.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day
        }

        let green = CodableColor(red: 0.30, green: 0.72, blue: 0.42)
        let olive = CodableColor(red: 0.56, green: 0.53, blue: 0.20)
        let red = CodableColor(red: 0.92, green: 0.22, blue: 0.20)
        let periwinkle = CodableColor(red: 0.51, green: 0.53, blue: 0.94)
        let blue = CodableColor(red: 0.15, green: 0.55, blue: 0.95)

        func event(_ id: String, _ title: String, _ location: String?, _ start: Date, _ end: Date, allDay: Bool = false, _ color: CodableColor, video: Bool = false, declined: Bool = false, tentative: Bool = false) -> AgendaEvent {
            AgendaEvent(id: id, title: title, location: location, start: start, end: end, isAllDay: allDay, calendarColor: color, calendarID: "sample", isVideoConference: video, isDeclined: declined, isTentative: tentative)
        }

        func timedItem(_ e: AgendaEvent) -> DayItem {
            DayItem(event: e, displayStart: e.start, displayEnd: e.end, continuesBeforeToday: false, continuesAfterToday: false)
        }
        func allDayItem(_ e: AgendaEvent, on day: Date) -> DayItem {
            DayItem(event: e, displayStart: day, displayEnd: cal.date(byAdding: .day, value: 1, to: day)!, continuesBeforeToday: false, continuesAfterToday: false)
        }

        let today = DaySection(day: day0, items: emptyToday ? [] : [
            allDayItem(event("s-bday", "Sam's Birthday", nil, day0, day1, allDay: true, green), on: day0),
            timedItem(event("s-review", "Quarterly Product Review", "Conference Room B", at(day0, 14, 0), at(day0, 15, 30), red)),
            timedItem(event("s-coffee", "Coffee with Alex", "Grove Street Café", at(day0, 16, 15), at(day0, 16, 45), periwinkle, tentative: true)),
        ])
        let sections = [
            today,
            DaySection(day: day1, items: [
                allDayItem(event("s-offsite", "Team Offsite", nil, day1, day2, allDay: true, olive), on: day1),
                timedItem(event("s-planning", "Roadmap Planning with the Platform Team", "Building 4, Room 210", at(day1, 13, 10), at(day1, 15, 10), red)),
            ]),
            DaySection(day: day2, items: [
                timedItem(event("s-training", "Personal Training", "120 Market Street, Suite 300", at(day2, 8, 0), at(day2, 9, 0), periwinkle)),
                timedItem(event("s-vendor", "Vendor Contract Review with Legal", "Riverside Office", at(day2, 15, 30), at(day2, 16, 0), CodableColor(red: 0.15, green: 0.35, blue: 0.85), declined: true)),
                timedItem(event("s-sync", "Weekly Partner Sync", nil, at(day2, 16, 0), at(day2, 17, 0), blue, video: true)),
            ]),
        ]

        return AgendaSnapshot(
            authorization: .fullAccess,
            sections: sections,
            page: 0,
            isContinuation: false,
            canPageBack: false,
            canPageForward: true,
            referenceDay: day0
        )
    }
}
