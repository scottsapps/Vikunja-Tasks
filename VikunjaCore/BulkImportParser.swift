import Foundation

struct BulkImportSpec {
    let projectName: String
    let labelTitles: [String]

    struct TaskEntry: Identifiable {
        let id = UUID()
        let title: String
        let dueDate: Date
    }

    let tasks: [TaskEntry]
    let skippedLines: [String]
}

struct BulkImportError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum BulkImportParser {
    static func parse(_ text: String) -> Result<BulkImportSpec, BulkImportError> {
        var lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Drop leading blank lines to be tolerant of text editors that insert them.
        while lines.first?.isEmpty == true { lines.removeFirst() }

        guard lines.count >= 2 else {
            return .failure(BulkImportError("File must contain a project name, a labels line, and at least one task."))
        }

        let projectName = lines[0]
        guard !projectName.isEmpty else {
            return .failure(BulkImportError("Project name (line 1) is empty."))
        }

        let labelsLine = lines[1]
        let labelTitles: [String] = labelsLine.isEmpty ? [] : labelsLine
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let taskLines = lines.dropFirst(2).filter { !$0.isEmpty }

        // The date column is ISO 8601 (yyyy-MM-dd), so the formatter is pinned to a
        // fixed locale — otherwise a device on a non-Gregorian calendar (Thai
        // Buddhist, Japanese imperial) reads the year in its own era. The calendar
        // day it yields is the user's own: due times are 8 PM local everywhere else
        // in the app, and an import is no different.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current

        var tasks: [BulkImportSpec.TaskEntry] = []
        var skipped: [String] = []

        for line in taskLines {
            guard line.count > 10 else {
                skipped.append(line)
                continue
            }
            let datePart = String(line.prefix(10))
            let title = String(line.dropFirst(10)).trimmingCharacters(in: .whitespaces)

            guard let midnight = fmt.date(from: datePart), !title.isEmpty else {
                skipped.append(line)
                continue
            }

            let dueDate = VikunjaAPI.applyDefaultTime(midnight)
            tasks.append(BulkImportSpec.TaskEntry(title: title, dueDate: dueDate))
        }

        if tasks.isEmpty {
            return .failure(BulkImportError("No valid task lines found. Each task line must start with yyyy-mm-dd followed by a space and the task title."))
        }

        return .success(BulkImportSpec(
            projectName: projectName,
            labelTitles: labelTitles,
            tasks: tasks,
            skippedLines: skipped
        ))
    }
}
