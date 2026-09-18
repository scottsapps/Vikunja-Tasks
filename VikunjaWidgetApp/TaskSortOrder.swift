import Foundation

// The order tasks appear in, as chosen in Settings. Day grouping itself is not
// negotiable — a Scheduled list that isn't in date order stops being a
// schedule — so these only decide the run *inside* a day, plus which end the
// undated tasks hang off.

/// What orders tasks inside a day (and inside the flat Inbox list).
enum TaskSortField: String, CaseIterable, Identifiable {
    case alphabetical
    case priority
    case project

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical: return "Alphabetical"
        case .priority:     return "Priority"
        case .project:      return "Project"
        }
    }
}

/// What breaks ties inside one project when `.project` is the sort field.
enum ProjectTieBreak: String, CaseIterable, Identifiable {
    case alphabetical
    case priority

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alphabetical: return "Alphabetical"
        case .priority:     return "Priority"
        }
    }
}

/// How the projects list itself is ordered — separate from `TaskSortField`,
/// which only orders the tasks inside a project/day, never the projects.
enum ProjectOrder: String, CaseIterable, Identifiable {
    /// Whatever order the server returned the projects in — Vikunja's own
    /// (drag/position) order, matching the web UI and other Vikunja clients.
    case server
    case alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .server:       return "Server Order"
        case .alphabetical: return "Alphabetical"
        }
    }
}

/// Which end of a dated list the tasks with no due date hang off.
enum UndatedPlacement: String, CaseIterable, Identifiable {
    case bottom
    case top

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .top:    return "Top"
        }
    }
}

/// The three preferences as one value, so a view can pass "how to sort"
/// around without re-reading defaults per comparison.
struct TaskSortOrder: Equatable {
    var field: TaskSortField = .alphabetical
    var projectTieBreak: ProjectTieBreak = .alphabetical
    var undated: UndatedPlacement = .bottom

    /// Orders one run of tasks — a single day's bucket, or the whole flat
    /// Inbox list. `projectNames` is `TaskStore.projectMap`; an id missing
    /// from it sorts as an empty name rather than dropping the task.
    func sorted(_ tasks: [VikunjaTask], projectNames: [Int: String]) -> [VikunjaTask] {
        tasks.sorted { lhs, rhs in
            switch field {
            case .alphabetical:
                break

            case .priority:
                if let byPriority = Self.byPriority(lhs, rhs) { return byPriority }

            case .project:
                let left = projectNames[lhs.projectId] ?? ""
                let right = projectNames[rhs.projectId] ?? ""
                switch left.localizedCompare(right) {
                case .orderedAscending:  return true
                case .orderedDescending: return false
                case .orderedSame:
                    if projectTieBreak == .priority,
                       let byPriority = Self.byPriority(lhs, rhs) { return byPriority }
                }
            }
            return Self.byTitle(lhs, rhs)
        }
    }

    /// Highest priority first. nil and 0 both mean "none" and sort last.
    /// nil when the two are equal, so the caller falls through to the next key.
    private static func byPriority(_ lhs: VikunjaTask, _ rhs: VikunjaTask) -> Bool? {
        let left = lhs.priority ?? 0
        let right = rhs.priority ?? 0
        return left == right ? nil : left > right
    }

    /// The last key in every ordering, so the result is a total order: Swift's
    /// `sorted` is not stable, and two tasks can genuinely share a title.
    private static func byTitle(_ lhs: VikunjaTask, _ rhs: VikunjaTask) -> Bool {
        switch lhs.title.localizedCompare(rhs.title) {
        case .orderedAscending:  return true
        case .orderedDescending: return false
        case .orderedSame:       return lhs.id < rhs.id
        }
    }
}

/// Storage for the ordering preference. `UserDefaults.standard` rather than
/// the App Group, matching the other app-only display settings (font size,
/// opening page) — no extension reads this, so the widgets keep their own
/// fixed order.
enum TaskSortPreferences {
    static let fieldKey = "vikunja_task_sort_field"
    static let projectTieBreakKey = "vikunja_task_sort_project_tiebreak"
    static let undatedKey = "vikunja_task_sort_undated"
    static let projectOrderKey = "vikunja_project_sort_order"

    /// Non-reactive read for call sites that aren't SwiftUI views (`TaskStore`
    /// is `@Observable`, but a plain `UserDefaults` read inside a computed
    /// property isn't a tracked dependency) — views pass their own
    /// `@AppStorage(projectOrderKey)` value instead so the list redraws the
    /// moment the setting changes.
    static var projectOrder: ProjectOrder {
        UserDefaults.standard.string(forKey: projectOrderKey)
            .flatMap(ProjectOrder.init(rawValue:)) ?? .server
    }
}
