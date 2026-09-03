import Foundation

// MARK: - Parsed result

struct QuickAddResult {
    var cleanedTitle: String
    var dueDate: Date?
    var repeatAfter: Int?        // seconds
    var repeatMode: Int?         // 0=default,1=monthly,2=from_current_date
    var priority: Int?           // 1–5
    var labelTitles: [String]
    var projectName: String?
}

// MARK: - Parser

/// Swift port of Vikunja's frontend parseTaskText.ts
/// Tokens (all case-insensitive, anywhere in the string):
///   *tag          → label
///   +project      → project (prefix-matched)
///   !1 – !5       → priority
///   Dates: today / tonight / tomorrow / tom / weekday name / "next <weekday>" /
///          "apr 30" / "2026-09-15" / "9/15" (locale-ordered) /
///          "in N days|weeks|months" / next week / next month / end of month
///   Recurrence: every day|week|month|year / daily|weekly|monthly|yearly /
///               "every N days" / "every two weeks" / every monday / every weekday
enum QuickAddParser {

    /// Digits or a spelled-out count, one–twelve ("every two weeks").
    private static let numberToken =
        #"(\d+|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"#

    static func parse(_ input: String, knownProjects: [VikunjaProject] = [], knownLabels: [VikunjaLabel] = []) -> QuickAddResult {
        var text = input
        var result = QuickAddResult(cleanedTitle: "", labelTitles: [])

        // Order matters: strip tokens from longest/most specific to shortest.
        result.repeatAfter = extractRepeat(&text, repeatMode: &result.repeatMode)
        result.dueDate = extractDate(&text)
        result.priority = extractPriority(&text)
        result.labelTitles = extractLabels(&text, knownLabels: knownLabels)
        result.projectName = extractProject(&text, knownProjects: knownProjects)
        result.cleanedTitle = text.trimmingCharacters(in: .whitespaces)

        return result
    }

    // MARK: - Recurrence

    private static func extractRepeat(_ text: inout String, repeatMode: inout Int?) -> Int? {
        // "every weekday" → weekdays only (approx. 5/7 of a week — store as weekly + mode)
        if let r = remove(pattern: #"\bevery\s+weekday\b"#, from: &text) {
            _ = r
            repeatMode = 0
            return 7 * 24 * 3600   // approximation; server handles weekday scheduling
        }

        // "every N days/weeks/months/years" — N as digits or a word ("every two weeks")
        let unitMap: [(String, Int)] = [
            ("years?", 365 * 24 * 3600),
            ("months?", 30 * 24 * 3600),
            ("weeks?", 7 * 24 * 3600),
            ("days?", 24 * 3600),
        ]
        for (unit, seconds) in unitMap {
            if let match = remove(pattern: #"\bevery\s+"# + numberToken + #"\s+"# + unit + #"\b"#, from: &text) {
                let n = intFromNumberToken(match)
                if n > 0 { return n * seconds }
            }
        }

        // "daily" / "weekly" / "monthly" / "yearly". Guarded so a *weekly label
        // or a +monthly project name is left untouched.
        let namedIntervals: [(String, Int)] = [
            ("daily", 24 * 3600),
            ("weekly", 7 * 24 * 3600),
            ("monthly", 30 * 24 * 3600),
            ("yearly", 365 * 24 * 3600),
        ]
        for (word, seconds) in namedIntervals {
            if remove(pattern: #"(?<![\w*+])"# + word + #"(?![\w-])"#, from: &text) != nil {
                return seconds
            }
        }

        // "every day / week / month / year"
        let singles: [(String, Int)] = [
            ("year", 365 * 24 * 3600),
            ("month", 30 * 24 * 3600),
            ("week", 7 * 24 * 3600),
            ("day", 24 * 3600),
        ]
        for (word, seconds) in singles {
            if remove(pattern: #"\bevery\s+"# + word + #"\b"#, from: &text) != nil {
                return seconds
            }
        }

        // "every monday" / "every tuesday" etc.
        let weekdays = ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"]
        for wd in weekdays {
            if remove(pattern: #"\bevery\s+"# + wd + #"\b"#, from: &text) != nil {
                return 7 * 24 * 3600
            }
        }

        return nil
    }

    // MARK: - Date

    private static func extractDate(_ text: inout String) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)

        // "in N days/weeks/months" — N as digits or a word ("in two weeks")
        let relativeUnits: [(String, Calendar.Component)] = [
            ("months?", .month), ("weeks?", .weekOfYear), ("days?", .day)
        ]
        for (unit, component) in relativeUnits {
            if let match = remove(pattern: #"\bin\s+"# + numberToken + #"\s+"# + unit + #"\b"#, from: &text) {
                let n = intFromNumberToken(match)
                if n > 0 { return cal.date(byAdding: component, value: n, to: todayStart) }
            }
        }

        // "next week" / "next month"
        if remove(pattern: #"\bnext\s+week\b"#, from: &text) != nil {
            return cal.date(byAdding: .weekOfYear, value: 1, to: todayStart)
        }
        if remove(pattern: #"\bnext\s+month\b"#, from: &text) != nil {
            return cal.date(byAdding: .month, value: 1, to: todayStart)
        }

        // "end of month" / "end of the month" → last day of the current month
        if remove(pattern: #"\bend\s+of\s+(?:the\s+)?month\b"#, from: &text) != nil {
            let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: todayStart)) ?? todayStart
            let nextMonthStart = cal.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
            return cal.date(byAdding: .day, value: -1, to: nextMonthStart)
        }

        // "tonight" → today. Veyrn applies the user's default due time on create,
        // so the evening intent collapses to that time anyway.
        if remove(pattern: #"(?<![\w*+])tonight(?![\w-])"#, from: &text) != nil {
            return todayStart
        }

        // "tomorrow" / "tom"
        if remove(pattern: #"\b(tomorrow|tom)\b"#, from: &text) != nil {
            return cal.date(byAdding: .day, value: 1, to: todayStart)
        }

        // "today"
        if remove(pattern: #"\btoday\b"#, from: &text) != nil {
            return todayStart
        }

        // Weekday names: "monday", "mon", etc. → next occurrence.
        // "next monday" forces the occurrence in the *following* week.
        let weekdayMap: [(String, Int)] = [
            ("monday|mon", 2), ("tuesday|tue", 3), ("wednesday|wed", 4),
            ("thursday|thu", 5), ("friday|fri", 6), ("saturday|sat", 7), ("sunday|sun", 1)
        ]
        for (pattern, weekday) in weekdayMap {
            if remove(pattern: #"\bnext\s+("# + pattern + #")\b"#, from: &text) != nil {
                let thisWeek = nextWeekday(weekday, after: todayStart, cal: cal)
                return cal.date(byAdding: .day, value: 7, to: thisWeek)
            }
            if remove(pattern: #"\b("# + pattern + #")\b"#, from: &text) != nil {
                return nextWeekday(weekday, after: todayStart, cal: cal)
            }
        }

        // "Apr 30", "April 30", "30 apr" etc.
        if let date = extractMonthDay(&text, cal: cal, todayStart: todayStart) {
            return date
        }

        // "2026-09-15", "9/15", "15/9/2026", "15.9.26"
        if let date = extractNumericDate(&text, cal: cal, todayStart: todayStart) {
            return date
        }

        return nil
    }

    private static func nextWeekday(_ weekday: Int, after date: Date, cal: Calendar) -> Date {
        let currentWeekday = cal.component(.weekday, from: date)
        var daysToAdd = weekday - currentWeekday
        if daysToAdd <= 0 { daysToAdd += 7 }
        return cal.date(byAdding: .day, value: daysToAdd, to: date)!
    }

    private static func extractMonthDay(_ text: inout String, cal: Calendar, todayStart: Date) -> Date? {
        // Matches "Apr 30", "April 30", "30 Apr", "30 April" — with optional year:
        // "Apr 30 2027", "Apr 30, 2027", "30 Apr 2027" (case-insensitive)
        let mn = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
        // Capture groups: (1) month-or-day, (2) day-or-month, (3) optional 4-digit year
        let patterns: [(String, Bool)] = [
            (#"\b("# + mn + #")\s+(\d{1,2})(?:[,\s]+(\d{4}))?\b"#, true),
            (#"\b(\d{1,2})\s+("# + mn + #")(?:[,\s]+(\d{4}))?\b"#, false)
        ]

        let monthNumbers = ["jan":1,"feb":2,"mar":3,"apr":4,"may":5,"jun":6,
                            "jul":7,"aug":8,"sep":9,"oct":10,"nov":11,"dec":12]

        for (pattern, monthFirst) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            else { continue }

            let fullRange = Range(m.range, in: text)!
            let g1 = Range(m.range(at: 1), in: text).map { String(text[$0]) }
            let g2 = Range(m.range(at: 2), in: text).map { String(text[$0]) }
            let g3 = m.numberOfRanges > 3 ? Range(m.range(at: 3), in: text).map { String(text[$0]) } : nil

            text.removeSubrange(fullRange)
            text = text.trimmingCharacters(in: .whitespaces)

            let monthStr = monthFirst ? g1 : g2
            let dayStr   = monthFirst ? g2 : g1
            guard let ms = monthStr, let ds = dayStr, let day = Int(ds) else { continue }
            let monthKey = String(ms.prefix(3).lowercased())
            guard let month = monthNumbers[monthKey] else { continue }

            var comps = DateComponents()
            comps.month = month
            comps.day = day
            if let yearStr = g3, let year = Int(yearStr) {
                comps.year = year
            } else {
                comps.year = cal.component(.year, from: todayStart)
                if let date = cal.date(from: comps), date < todayStart {
                    comps.year! += 1
                }
            }
            return cal.date(from: comps)
        }
        return nil
    }

    // MARK: - Numeric dates

    /// ISO dates (`2026-09-15`) and separator dates (`9/15`, `15/9/2026`,
    /// `15.9.26`). A separator date with no year is only accepted when one
    /// component is > 12, so the field order is unambiguous — a bare `3/4` is
    /// left in the title rather than guessed. When a year is present and both
    /// components are ≤ 12, the order follows the reader's locale.
    private static func extractNumericDate(_ text: inout String, cal: Calendar, todayStart: Date) -> Date? {
        let currentYear = cal.component(.year, from: todayStart)

        // ISO 8601 calendar date — always unambiguous.
        if let (range, groups) = firstRegexMatch(#"(?<![\w*+/.\-])(\d{4})-(\d{1,2})-(\d{1,2})\b"#, in: text),
           let year = Int(groups[1]), let month = Int(groups[2]), let day = Int(groups[3]),
           let date = calendarDate(year: year, month: month, day: day, cal: cal) {
            text.removeSubrange(range)
            text = collapseSpaces(text)
            return date
        }

        // "9/15", "15/9/2026", "15.9.26", "9.15.2026"
        guard let (range, groups) = firstRegexMatch(
                #"(?<![\w*+/.\-])(\d{1,2})[./](\d{1,2})(?:[./](\d{2,4}))?\b"#, in: text),
              let a = Int(groups[1]), let b = Int(groups[2]) else { return nil }

        let yearString = groups.count > 3 ? groups[3] : ""
        let hasYear = !yearString.isEmpty

        let month: Int
        let day: Int
        if a > 12, b <= 12 {              // 15/9  → day / month
            day = a; month = b
        } else if b > 12, a <= 12 {       // 9/15  → month / day
            month = a; day = b
        } else if hasYear {              // 3/4/2026 → locale order decides
            if localeDayBeforeMonth { day = a; month = b } else { month = a; day = b }
        } else {
            return nil                    // bare "3/4" — too ambiguous to guess
        }

        let year = hasYear ? normalizedYear(yearString) : currentYear
        guard var date = calendarDate(year: year, month: month, day: day, cal: cal) else { return nil }
        if !hasYear, date < todayStart {
            date = cal.date(byAdding: .year, value: 1, to: date) ?? date
        }
        text.removeSubrange(range)
        text = collapseSpaces(text)
        return date
    }

    /// A real calendar date, or nil when the components don't exist (e.g. Feb 30).
    private static func calendarDate(year: Int, month: Int, day: Int, cal: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        guard let date = cal.date(from: comps) else { return nil }
        let roundTrip = cal.dateComponents([.month, .day], from: date)
        return (roundTrip.month == month && roundTrip.day == day) ? date : nil
    }

    /// Two-digit years map into the 2000s; anything else is taken as written.
    private static func normalizedYear(_ raw: String) -> Int {
        let n = Int(raw) ?? 0
        return raw.count == 2 ? 2000 + n : n
    }

    /// Whether the reader's locale writes the day before the month in an
    /// all-digits date (true across most of the world, false for `M/d/y`
    /// locales like en-US).
    private static var localeDayBeforeMonth: Bool {
        let fmt = DateFormatter()
        fmt.locale = .current
        fmt.setLocalizedDateFormatFromTemplate("yMd")
        let pattern = fmt.dateFormat ?? "M/d/y"
        guard let dayIndex = pattern.firstIndex(of: "d"),
              let monthIndex = pattern.firstIndex(of: "M") else { return true }
        return dayIndex < monthIndex
    }

    // MARK: - Priority

    private static func extractPriority(_ text: inout String) -> Int? {
        guard let match = remove(pattern: #"\!([1-5])\b"#, from: &text),
              let n = Int(match) else { return nil }
        return n
    }

    // MARK: - Labels

    private static func extractLabels(_ text: inout String, knownLabels: [VikunjaLabel]) -> [String] {
        var labels: [String] = []
        let pattern = #"\*(\w[\w\-]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }

        var remaining = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            if let groupRange = Range(match.range(at: 1), in: text) {
                let typed = String(text[groupRange])
                let resolved: String
                if !knownLabels.isEmpty,
                   let matched = knownLabels.first(where: { $0.title.lowercased().hasPrefix(typed.lowercased()) }) {
                    resolved = matched.title
                } else {
                    resolved = typed
                }
                labels.append(resolved)
            }
            if let fullRange = Range(match.range, in: text) {
                remaining.removeSubrange(fullRange)
            }
        }
        text = remaining.trimmingCharacters(in: .whitespaces)
        return labels.reversed()
    }

    // MARK: - Project

    private static func extractProject(_ text: inout String, knownProjects: [VikunjaProject]) -> String? {
        guard let name = remove(pattern: #"\+(\w[\w\-]*)"#, from: &text) else { return nil }

        // Case-insensitive prefix match against known projects
        if !knownProjects.isEmpty {
            let lower = name.lowercased()
            if let match = knownProjects.first(where: { $0.title.lowercased().hasPrefix(lower) }) {
                return match.title
            }
        }
        return name
    }

    // MARK: - Regex helper

    /// Removes first match of pattern (case-insensitive) from text.
    /// Returns the first capture group string if there is one, else the full match string.
    @discardableResult
    private static func remove(pattern: String, from text: inout String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        let fullRange = Range(match.range, in: text)!
        let captureStr: String?
        if match.numberOfRanges > 1, let capRange = Range(match.range(at: 1), in: text) {
            captureStr = String(text[capRange])
        } else {
            captureStr = String(text[fullRange])
        }

        text.removeSubrange(fullRange)
        text = collapseSpaces(text)
        return captureStr
    }

    /// First case-insensitive match of `pattern`, as (full range, group strings).
    /// `groups[0]` is the whole match; groups that did not participate come back
    /// as "".
    private static func firstRegexMatch(_ pattern: String, in text: String) -> (Range<String.Index>, [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let fullRange = Range(match.range, in: text) else { return nil }

        var groups: [String] = []
        for index in 0..<match.numberOfRanges {
            if let groupRange = Range(match.range(at: index), in: text) {
                groups.append(String(text[groupRange]))
            } else {
                groups.append("")
            }
        }
        return (fullRange, groups)
    }

    /// Digit string or spelled-out one–twelve → Int (0 when unrecognized).
    private static func intFromNumberToken(_ token: String) -> Int {
        if let n = Int(token) { return n }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                     "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
        return words[token.lowercased()] ?? 0
    }

    /// Squeezes the double space a mid-string token removal leaves behind, then trims.
    private static func collapseSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
