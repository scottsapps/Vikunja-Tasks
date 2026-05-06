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
///   today / tomorrow / tom / weekday name / "apr 30" / "in N days|weeks|months" / "next week"
///   every day|week|month|year / every N days / every monday / every weekday
enum QuickAddParser {

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

        // "every N days/weeks/months/years"
        let unitMap: [(String, Int)] = [
            ("years?", 365 * 24 * 3600),
            ("months?", 30 * 24 * 3600),
            ("weeks?", 7 * 24 * 3600),
            ("days?", 24 * 3600),
        ]
        for (unit, seconds) in unitMap {
            if let match = remove(pattern: #"\bevery\s+(\d+)\s+"# + unit + #"\b"#, from: &text),
               let n = Int(match) {
                return n * seconds
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

        // "in N days/weeks/months"
        let relativeUnits: [(String, Calendar.Component)] = [
            ("months?", .month), ("weeks?", .weekOfYear), ("days?", .day)
        ]
        for (unit, component) in relativeUnits {
            if let match = remove(pattern: #"\bin\s+(\d+)\s+"# + unit + #"\b"#, from: &text),
               let n = Int(match) {
                return cal.date(byAdding: component, value: n, to: todayStart)
            }
        }

        // "next week"
        if remove(pattern: #"\bnext\s+week\b"#, from: &text) != nil {
            return cal.date(byAdding: .weekOfYear, value: 1, to: todayStart)
        }

        // "tomorrow" / "tom"
        if remove(pattern: #"\b(tomorrow|tom)\b"#, from: &text) != nil {
            return cal.date(byAdding: .day, value: 1, to: todayStart)
        }

        // "today"
        if remove(pattern: #"\btoday\b"#, from: &text) != nil {
            return todayStart
        }

        // Weekday names: "monday", "mon", etc. → next occurrence
        let weekdayMap: [(String, Int)] = [
            ("monday|mon", 2), ("tuesday|tue", 3), ("wednesday|wed", 4),
            ("thursday|thu", 5), ("friday|fri", 6), ("saturday|sat", 7), ("sunday|sun", 1)
        ]
        for (pattern, weekday) in weekdayMap {
            if remove(pattern: #"\b("# + pattern + #")\b"#, from: &text) != nil {
                return nextWeekday(weekday, after: todayStart, cal: cal)
            }
        }

        // "Apr 30", "April 30", "30 apr" etc.
        if let date = extractMonthDay(&text, cal: cal, todayStart: todayStart) {
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
        text = text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
        return captureStr
    }
}
