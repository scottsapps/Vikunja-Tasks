import Foundation

/// Turns a spoken sentence into the same `QuickAddResult` the typed Quick Add
/// produces. Siri hands Veyrn plain words ("remind me tomorrow to file the
/// pleading in project Litigation and tag it court, high priority"), not the
/// `+project *tag !3` shorthand, and in any order — so this pass pulls out the
/// project, tags and priority by their spoken markers, rewrites spoken date
/// forms the typed parser doesn't know ("the 9th of October", "day after
/// tomorrow", "due on Friday"), then hands the rest to `QuickAddParser` for
/// dates and recurrence. Anything the user *did* say in shorthand still works.
///
/// Projects and tags are matched against the names Veyrn already knows,
/// longest first, so multi-word names ("Smith v. Jones") survive. An unknown
/// project name is left in the title rather than guessed; an unknown tag is
/// accepted (Quick Add creates it), but only a single word and never a
/// function word, so "tag" inside an ordinary title doesn't swallow the
/// following "for" or "the".
enum SpokenTaskParser {

    static func parse(_ input: String, knownProjects: [VikunjaProject], knownLabels: [VikunjaLabel]) -> QuickAddResult {
        var text = " " + input.trimmingCharacters(in: .whitespacesAndNewlines) + " "

        stripLeadIn(&text)
        let projectTitle = extractProject(&text, knownProjects: knownProjects)
        let labelTitles = extractTags(&text, knownLabels: knownLabels)
        let priority = extractPriority(&text)
        normalizeDates(&text)

        protectAbbreviations(&text)
        var result = QuickAddParser.parse(collapse(text), knownProjects: knownProjects, knownLabels: knownLabels)
        result.cleanedTitle = result.cleanedTitle.replacingOccurrences(of: wordJoiner, with: "")
        if let projectTitle { result.projectName = projectTitle }
        for title in labelTitles where !result.labelTitles.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
            result.labelTitles.append(title)
        }
        if let priority { result.priority = priority }
        result.cleanedTitle = tidyTitle(result.cleanedTitle)
        return result
    }

    // MARK: - Lead-in

    /// "Remind me to …", "add a task to …", "create a new task called …" —
    /// the framing, not the task.
    private static func stripLeadIn(_ text: inout String) {
        replace(#"^\s*(?:please\s+)?(?:remind\s+me|remember)(?:\s+to)?\s+"#, in: &text, with: " ")
        replace(#"^\s*(?:please\s+)?(?:add|create|make|new)\s+(?:a\s+)?(?:new\s+)?(?:task|to-?do|reminder)(?:\s+(?:called|named|to|that\s+says))?\s+"#, in: &text, with: " ")
    }

    // MARK: - Project

    private static let projectLead = #"(?:(?:,\s*)?(?:and\s+)?(?:put\s+it\s+|file\s+it\s+|add\s+it\s+)?(?:in|into|to|for|under|on)\s+(?:the\s+)?)"#

    private static func extractProject(_ text: inout String, knownProjects: [VikunjaProject]) -> String? {
        let byLength = knownProjects.sorted { $0.title.count > $1.title.count }
        for project in byLength {
            let name = NSRegularExpression.escapedPattern(for: project.title)
            // "in project Litigation" / "project Litigation"
            if removeFirst(#"(?i)"# + projectLead + #"?\b(?:project|list)\s+"# + name + #"(?=[\s,.!?])"#, from: &text) {
                return project.title
            }
            // "in the Litigation project"
            if removeFirst(#"(?i)"# + projectLead + name + #"\s+(?:project|list)\b"#, from: &text) {
                return project.title
            }
        }
        // A single spoken word naming the start of a project ("project lit"),
        // the same prefix rule Quick Add uses for "+lit".
        if let (range, groups) = match(#"(?i)"# + projectLead + #"?\b(?:project|list)\s+([\w\-]+)"#, in: text) {
            let word = groups[1].lowercased()
            if let project = byLength.reversed().first(where: { $0.title.lowercased().hasPrefix(word) }) {
                text.replaceSubrange(range, with: " ")
                return project.title
            }
        }
        return nil
    }

    // MARK: - Tags

    private static let tagLead =
        #"(?i)(?:,\s*)?(?:\band\s+)?(?:\bwith\s+(?:the\s+)?)?\b(?:tag(?:s|ged)?|label(?:s|led|ed)?)(?:\s+(?:it|this|that|them))?(?:\s+(?:with|as))?\s+"#

    /// Words never taken as a brand-new tag name.
    private static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "for", "to", "of", "in", "on", "at", "by",
        "with", "it", "this", "that", "due", "priority", "project", "tomorrow", "today",
    ]

    private static func extractTags(_ text: inout String, knownLabels: [VikunjaLabel]) -> [String] {
        let byLength = knownLabels.sorted { $0.title.count > $1.title.count }
        var found: [String] = []

        // Several tag phrases are fine ("tag it court … and label it urgent").
        for _ in 0..<3 {
            guard let (leadRange, _) = match(tagLead, in: text) else { break }
            var cursor = leadRange.upperBound
            var names: [String] = []

            while cursor < text.endIndex {
                let rest = text[cursor...]
                if let known = byLength.first(where: { startsWithWord($0.title, in: rest) }) {
                    names.append(known.title)
                    cursor = text.index(cursor, offsetBy: known.title.count)
                } else if let word = firstWord(of: rest),
                          !stopWords.contains(word.lowercased()),
                          names.isEmpty || isFollowedByEndOrComma(text, after: text.index(cursor, offsetBy: word.count)) {
                    names.append(word)
                    cursor = text.index(cursor, offsetBy: word.count)
                } else {
                    break
                }
                // Another name follows only after ",", "and" or "&".
                let tail = String(text[cursor...])
                guard let (sepRange, _) = match(#"^\s*(?:,\s*(?:and\s+)?|and\s+|&\s*)"#, in: tail) else { break }
                let sepLength = tail.distance(from: tail.startIndex, to: sepRange.upperBound)
                let next = text.index(cursor, offsetBy: sepLength)
                // Don't eat an "and" that leads into the next phrase instead of a name.
                let after = text[next...]
                if byLength.contains(where: { startsWithWord($0.title, in: after) }) {
                    cursor = next
                } else if let word = firstWord(of: after),
                          !stopWords.contains(word.lowercased()),
                          isFollowedByEndOrComma(text, after: text.index(next, offsetBy: word.count)) {
                    cursor = next
                } else {
                    break
                }
            }

            guard !names.isEmpty else { break }
            text.replaceSubrange(leadRange.lowerBound..<cursor, with: " ")
            for name in names where !found.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                found.append(name)
            }
        }
        return found
    }

    // MARK: - Priority

    private static let priorityWords: [String: Int] = [
        "1": 1, "one": 1, "low": 1, "lowest": 1,
        "2": 2, "two": 2, "medium": 2, "normal": 2,
        "3": 3, "three": 3, "high": 3, "important": 3,
        "4": 4, "four": 4, "urgent": 4,
        "5": 5, "five": 5, "critical": 5, "highest": 5, "top": 5, "do now": 5,
    ]

    private static func extractPriority(_ text: inout String) -> Int? {
        let word = #"(do\s+now|lowest|low|medium|normal|highest|high|important|urgent|critical|top|[1-5]|one|two|three|four|five)"#
        let lead = #"(?i)(?:,\s*)?(?:\band\s+)?(?:\bwith\s+)?(?:\b(?:a|an)\s+)?"#
        let patterns = [
            lead + #"\b(?:set\s+(?:the\s+)?)?priority\s+(?:to\s+|of\s+|is\s+|at\s+)?"# + word + #"\b"#,
            lead + #"\bp([1-5])\b"#,
            lead + #"\b"# + word + #"\s+priority\b"#,
            lead + #"\b(?:mark|make|set)(?:\s+it)?(?:\s+as)?\s+(urgent|important|critical)\b"#,
        ]
        for pattern in patterns {
            if let (range, groups) = match(pattern, in: text),
               let n = priorityWords[groups[1].lowercased().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)] {
                text.replaceSubrange(range, with: " ")
                return n
            }
        }
        return nil
    }

    // MARK: - Dates

    /// Rewrites spoken date forms into ones `QuickAddParser` reads, and drops
    /// the "due on" / "by" in front of a date so it doesn't stay in the title.
    /// A spoken clock time is dropped: a due date is a deadline day, and Veyrn
    /// snaps it to the default due time on create.
    private static func normalizeDates(_ text: inout String) {
        let month = #"(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"#
        replace(#"(?i)\b(?:the\s+)?day\s+after\s+tomorrow\b"#, in: &text, with: "in 2 days")
        // "the 9th of October" → "9 October"; "October the 9th" → "October 9"
        replace(#"(?i)\b(?:the\s+)?(\d{1,2})(?:st|nd|rd|th)?\s+of\s+("# + month + #")\b"#, in: &text, with: "$1 $2")
        replace(#"(?i)\b("# + month + #")\s+the\s+(\d{1,2})"#, in: &text, with: "$1 $2")
        replace(#"(?i)\b(\d{1,2})(?:st|nd|rd|th)\b"#, in: &text, with: "$1")
        // "this Friday" → "Friday"
        replace(#"(?i)\bthis\s+(?=(?:mon|tues|wednes|thurs|fri|satur|sun)day\b)"#, in: &text, with: "")

        let dateStart = #"(?=(?:today|tonight|tomorrow|next\s|in\s+\w+\s+(?:days?|weeks?|months?)|end\s+of|(?:mon|tues|wednes|thurs|fri|satur|sun)day|"# + month + #"\b|\d{1,2}\s+"# + month + #"|\d{1,2}[/.]\d|\d{4}-\d))"#
        replace(#"(?i)(?:,\s*)?(?:\band\s+)?\b(?:(?:it'?s\s+|it\s+is\s+)?due(?:\s+date)?(?:\s+(?:on|by|for))?|deadline(?:\s+(?:is|of))?|by|on|before|for)\s+"# + dateStart, in: &text, with: " ")

        replace(#"(?i)(?:,\s*)?\b(?:at\s+)?\d{1,2}(?::\d{2})?\s*(?:a\.?\s?m\.?|p\.?\s?m\.?|o'?clock)(?=[\s,.!?]|$)"#, in: &text, with: " ")
        replace(#"(?i)\b(?:at\s+)?noon\b"#, in: &text, with: " ")
    }

    // MARK: - Abbreviations

    /// U+2060 WORD JOINER: invisible, and splits a word for `\b` purposes.
    private static let wordJoiner = "\u{2060}"

    /// `QuickAddParser` reads "tom", "sat", "wed", "sun" … as dates, which is
    /// right for typing and wrong for speech: Siri transcribes a spoken date
    /// in full ("Saturday"), so a bare "Tom" or "sat" is a name or a word.
    /// Splitting it with a word joiner hides it from those patterns; the
    /// joiner comes back out of the title afterwards.
    private static func protectAbbreviations(_ text: inout String) {
        replace(#"(?i)\b(t)(om|ue|hu)\b"#, in: &text, with: "$1" + wordJoiner + "$2")
        replace(#"(?i)\b(m)(on)\b"#, in: &text, with: "$1" + wordJoiner + "$2")
        replace(#"(?i)\b(w)(ed)\b"#, in: &text, with: "$1" + wordJoiner + "$2")
        replace(#"(?i)\b(f)(ri)\b"#, in: &text, with: "$1" + wordJoiner + "$2")
        replace(#"(?i)\b(s)(at|un)\b"#, in: &text, with: "$1" + wordJoiner + "$2")
    }

    // MARK: - Title clean-up

    /// Removes the joints left behind where phrases came out: a dangling
    /// "and"/"with"/comma, a leading "to" from "remind me tomorrow to …".
    private static func tidyTitle(_ raw: String) -> String {
        var t = " " + raw + " "
        replace(#"\s+,"#, in: &t, with: ",")
        replace(#",(\s*,)+"#, in: &t, with: ",")
        for _ in 0..<3 {
            replace(#"(?i)^[\s,.;:]*(?:(?:and|to|that|about|with|then)(?=\s))?[\s,.;:]*"#, in: &t, with: "")
            replace(#"(?i)[\s,;:]*(?:(?<=\s)(?:and|with|then|due))?[\s,;:.!?]*$"#, in: &t, with: "")
        }
        t = collapse(t)
        guard let first = t.first else { return t }
        return first.uppercased() + String(t.dropFirst())
    }

    // MARK: - Helpers

    private static func startsWithWord(_ name: String, in rest: Substring) -> Bool {
        guard rest.count >= name.count,
              rest.prefix(name.count).caseInsensitiveCompare(name) == .orderedSame else { return false }
        let after = rest.dropFirst(name.count).first
        return after == nil || !(after!.isLetter || after!.isNumber)
    }

    private static func firstWord(of rest: Substring) -> String? {
        let word = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return word.isEmpty ? nil : String(word)
    }

    /// True when only whitespace and then a comma, "and", or the end follows —
    /// i.e. this word closes a tag list rather than starting the task title.
    private static func isFollowedByEndOrComma(_ text: String, after index: String.Index) -> Bool {
        let rest = text[index...]
        let trimmed = rest.drop { $0 == " " }
        if trimmed.isEmpty { return true }
        if let c = trimmed.first, ",.!?&".contains(c) { return true }
        return trimmed.lowercased().hasPrefix("and ")
    }

    @discardableResult
    private static func removeFirst(_ pattern: String, from text: inout String) -> Bool {
        guard let (range, _) = match(pattern, in: text) else { return false }
        text.replaceSubrange(range, with: " ")
        return true
    }

    private static func replace(_ pattern: String, in text: inout String, with template: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
        text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// First match as (full range, groups); groups that didn't take part come back "".
    private static func match(_ pattern: String, in text: String) -> (Range<String.Index>, [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let full = Range(m.range, in: text) else { return nil }
        let groups = (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
        return (full, groups)
    }

    private static func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
