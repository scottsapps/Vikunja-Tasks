import Foundation

/// The words Veyrn shows in place of a date — "Today", "Tomorrow", "Overdue" —
/// and the three shapes of day label the UI asks for.
///
/// Every surface that labels a day comes through here: the Quick Add and editor
/// chips, task rows, the list's section headers, the widget timeline, and the
/// watch. One copy of the wording is what makes it translatable at all — a label
/// assembled inline out of a plain `String` is invisible to the string catalog,
/// so it would stay English even in a fully localized build.
///
/// Dates themselves are never pattern-formatted here: `Date.FormatStyle` picks
/// the field *order* for the reader's region, so "Aug 28" and "28. Aug." both
/// fall out of the same call.
enum DayLabel {

    // MARK: - The bare words

    static var today: String {
        String(localized: "Today", comment: "Stands in for today's date on a task or section header")
    }
    static var tomorrow: String {
        String(localized: "Tomorrow", comment: "Stands in for tomorrow's date on a task or section header")
    }
    static var overdue: String {
        String(localized: "Overdue", comment: "Shown on a task whose due date has already passed")
    }
    static var noDate: String {
        String(localized: "No Date", comment: "Section header grouping tasks that have no due date")
    }

    // MARK: - Shapes

    /// Chips and row badges, where there is room for a word or a short date:
    /// "Today", "Tomorrow", "Overdue", or "Aug 28" / "28. Aug." / "8月28日".
    static func compact(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch relation(of: date, to: now, calendar: calendar) {
        case .past:     return overdue
        case .today:    return today
        case .tomorrow: return tomorrow
        case .later:    return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    /// Section headers in the task list and the widget: "Today", "Tomorrow", or a
    /// weekday and date. The year appears only for a day outside the current one,
    /// so next January reads as a different year rather than a puzzling near date.
    ///
    /// Callers fold overdue tasks into today's bucket, so `.past` should not reach
    /// here; it falls through to the dated form rather than inventing a heading.
    static func groupHeader(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch relation(of: day, to: now, calendar: calendar) {
        case .today:    return today
        case .tomorrow: return tomorrow
        case .past, .later:
            let style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
            return calendar.component(.year, from: day) == calendar.component(.year, from: now)
                ? day.formatted(style)
                : day.formatted(style.year())
        }
    }

    /// The watch's day titles, where only one word fits: "Today", "Tomorrow", "Friday".
    static func weekday(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch relation(of: day, to: now, calendar: calendar) {
        case .today:        return today
        case .tomorrow:     return tomorrow
        case .past, .later: return day.formatted(.dateTime.weekday(.wide))
        }
    }

    // MARK: - Day arithmetic

    private enum Relation { case past, today, tomorrow, later }

    /// Compares whole calendar days, not instants — two timestamps hours apart are
    /// the same day, and "tomorrow" survives a daylight-saving boundary because the
    /// calendar does the adding.
    private static func relation(of date: Date, to now: Date, calendar: Calendar) -> Relation {
        let startOfToday = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day < startOfToday { return .past }
        if day == startOfToday { return .today }
        if day == calendar.date(byAdding: .day, value: 1, to: startOfToday) { return .tomorrow }
        return .later
    }
}
