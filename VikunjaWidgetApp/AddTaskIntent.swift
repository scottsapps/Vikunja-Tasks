#if os(iOS)
import AppIntents
import Foundation

// MARK: - Siri: Add Task

/// "Siri, add a task in Veyrn" — and, with the iOS 27 Siri, the whole thing in
/// one sentence in any order ("remind me tomorrow to file the pleading in
/// project Litigation and tag it court").
///
/// Two ways the details arrive, and both are honored:
/// - Siri fills the typed parameters itself (`dueDate`, `project`, `tags`,
///   `priority`) when it understands them. These win.
/// - Everything else is spoken into `text`, which goes through
///   `SpokenTaskParser` — so on a Siri that only asks "What's the task?", the
///   answer "file the pleading tomorrow in project Litigation, high priority"
///   still lands fully formed.
///
/// Siri reads the parsed task back and waits for a yes before anything is
/// queued. The task then goes through the same `TaskStore.createTask` outbox
/// path as Quick Add, so it survives being offline.
///
/// iPhone only by decision; the file is compiled into the macOS app too, hence
/// the fence.
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription(
        "Adds a task to Veyrn. Say the due date, project, tags and priority in any order."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Task", requestValueDialog: IntentDialog("What's the task?"))
    var text: String

    @Parameter(title: "Due Date", kind: .date)
    var dueDate: Date?

    @Parameter(title: "Project")
    var project: VeyrnProjectEntity?

    @Parameter(title: "Tags")
    var tags: [VeyrnTagEntity]?

    @Parameter(title: "Priority")
    var priority: VeyrnPriority?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$project)") {
            \.$dueDate
            \.$tags
            \.$priority
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard VikunjaConfig.isConfigured else { throw AddTaskError.notSignedIn }
        let store = TaskStore.shared

        let parsed = SpokenTaskParser.parse(text, knownProjects: store.writableProjects, knownLabels: store.labels)
        guard !parsed.cleanedTitle.isEmpty else {
            throw $text.needsValueError("What's the task?")
        }
        let title = parsed.cleanedTitle

        // Project: Siri's pick, then one named in the sentence, then the Inbox.
        let spokenProject = parsed.projectName.flatMap { name in
            store.writableProjects.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
                ?? store.writableProjects.first { $0.title.lowercased().hasPrefix(name.lowercased()) }
        }
        let chosenProject = project.flatMap { entity in store.writableProjects.first { $0.id == entity.id } }
        guard let target = chosenProject ?? spokenProject ?? store.inboxProject ?? store.writableProjects.first else {
            throw AddTaskError.noProjects
        }

        let due = dueDate ?? parsed.dueDate
        let priorityValue = priority?.rawValue ?? parsed.priority
        var tagTitles: [String] = []
        for name in (tags ?? []).map(\.title) + parsed.labelTitles
        where !tagTitles.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            tagTitles.append(name)
        }

        let readBack = Self.readBack(title: title, project: target.title, due: due, tags: tagTitles, priority: priorityValue)
        if #available(iOS 18.0, *) {
            try await requestConfirmation(actionName: .add, dialog: readBack)
        } else {
            try await (self as LegacyConfirmation).legacyConfirm(readBack)
        }

        // Same rule as Quick Add: a known tag is reused, an unknown one is
        // created when online and dropped when not.
        var labels: [VikunjaLabel] = []
        for name in tagTitles {
            if let existing = store.labels.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                labels.append(existing)
            } else if store.reachability.isOnline,
                      let created = try? await VikunjaAPI.createLabel(title: name) {
                labels.append(created)
                store.labels.append(created)
            }
        }

        guard let opId = store.createTask(
            projectId: target.id,
            title: title,
            dueDate: due,
            priority: priorityValue,
            labels: labels,
            repeatAfter: parsed.repeatAfter,
            repeatMode: parsed.repeatMode,
            source: "siri"
        ) else {
            throw AddTaskError.readOnly
        }
        DiagnosticLog.info("siri add task queued (due: \(due != nil), tags: \(labels.count), priority: \(priorityValue != nil))")

        // A background launch can be suspended as soon as `perform` returns,
        // so wait (briefly) for the create to actually reach the server.
        if await Self.waitUntilSent(opId, store: store) {
            return .result(dialog: "Added to \(target.title).")
        }
        DiagnosticLog.info("siri add task left in outbox")
        return .result(dialog: "Saved. It will sync to \(target.title) the next time Veyrn is online.")
    }

    /// "Add “File the pleading” to Litigation, due Thursday, October 8, tagged court, high priority?"
    private static func readBack(title: String, project: String, due: Date?, tags: [String], priority: Int?) -> IntentDialog {
        var details: [String] = []
        if let due {
            let day = due.formatted(.dateTime.weekday(.wide).month(.wide).day())
            details.append(String(localized: "due \(day)"))
        }
        if !tags.isEmpty {
            details.append(String(localized: "tagged \(tags.formatted(.list(type: .and)))"))
        }
        if let priority, let name = VeyrnPriority(rawValue: priority)?.spokenName {
            details.append(name)
        }
        if details.isEmpty {
            return IntentDialog("Add “\(title)” to \(project)?")
        }
        let joined = details.joined(separator: ", ")
        return IntentDialog("Add “\(title)” to \(project), \(joined)?")
    }

    /// Polls in short hops against a wall-clock deadline (see SKILL.md: a
    /// single long sleep doesn't advance while the device sleeps).
    @MainActor
    private static func waitUntilSent(_ opId: UUID, store: TaskStore) async -> Bool {
        guard store.reachability.isOnline else { return false }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !store.outbox.ops.contains(where: { $0.id == opId }) { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return !store.outbox.ops.contains(where: { $0.id == opId })
    }
}

/// iOS 17 fallback for the read-back. Apple deprecated the old
/// `requestConfirmation(result:…)` outright (not "from iOS 18"), so a direct
/// call warns even behind `#available`, while its replacement needs iOS 18.
/// A deprecated declaration may use deprecated API silently, and calling it
/// through this non-deprecated protocol requirement keeps the call site
/// quiet too. Drop this when the deployment target reaches iOS 18.
private protocol LegacyConfirmation {
    func legacyConfirm(_ dialog: IntentDialog) async throws
}

extension AddTaskIntent: LegacyConfirmation {
    @available(*, deprecated, message: "iOS 17 only — see LegacyConfirmation")
    func legacyConfirm(_ dialog: IntentDialog) async throws {
        try await requestConfirmation(result: .result(dialog: dialog), confirmationActionName: .add)
    }
}

enum AddTaskError: Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case noProjects
    case readOnly

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Open Veyrn and connect it to your Vikunja server first."
        case .noProjects: return "Open Veyrn once so it can load your projects, then try again."
        case .readOnly: return "That project is shared with you read-only, so Veyrn can't add tasks to it."
        }
    }
}

// MARK: - Projects and tags Siri can name

struct VeyrnProjectEntity: AppEntity {
    let id: Int
    let title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = VeyrnProjectQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(_ project: VikunjaProject) {
        id = project.id
        title = project.title
    }
}

struct VeyrnProjectQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [Int]) async throws -> [VeyrnProjectEntity] {
        TaskStore.shared.writableProjects.filter { identifiers.contains($0.id) }.map(VeyrnProjectEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [VeyrnProjectEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces)
        return TaskStore.shared.writableProjects
            .filter { $0.title.localizedCaseInsensitiveContains(needle) }
            .map(VeyrnProjectEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [VeyrnProjectEntity] {
        TaskStore.shared.writableProjects.map(VeyrnProjectEntity.init)
    }
}

struct VeyrnTagEntity: AppEntity {
    let id: Int
    let title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tag"
    static let defaultQuery = VeyrnTagQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    init(_ label: VikunjaLabel) {
        id = label.id
        title = label.title
    }
}

struct VeyrnTagQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [Int]) async throws -> [VeyrnTagEntity] {
        TaskStore.shared.labels.filter { identifiers.contains($0.id) }.map(VeyrnTagEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [VeyrnTagEntity] {
        let needle = string.trimmingCharacters(in: .whitespaces)
        return TaskStore.shared.labels
            .filter { $0.title.localizedCaseInsensitiveContains(needle) }
            .map(VeyrnTagEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [VeyrnTagEntity] {
        TaskStore.shared.labels.map(VeyrnTagEntity.init)
    }
}

/// Vikunja's 1–5 scale, with the names the task editor uses.
enum VeyrnPriority: Int, AppEnum {
    case low = 1, medium, high, urgent, critical

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Priority"
    static let caseDisplayRepresentations: [VeyrnPriority: DisplayRepresentation] = [
        .low: "Low",
        .medium: "Medium",
        .high: "High",
        .urgent: "Urgent",
        .critical: "Critical",
    ]

    var spokenName: String {
        switch self {
        case .low: return String(localized: "low priority")
        case .medium: return String(localized: "medium priority")
        case .high: return String(localized: "high priority")
        case .urgent: return String(localized: "urgent priority")
        case .critical: return String(localized: "critical priority")
        }
    }
}

// MARK: - Siri phrases

/// Phrases work with no setup. Each must name the app; `.applicationName`
/// also matches the spoken alternatives in `InfoIOS.plist`
/// (`INAlternativeAppNames`), since "Veyrn" is easy to mishear. A phrase can
/// only carry an entity or enum parameter, never free text — the task itself
/// is asked for ("What's the task?") unless the iOS 27 Siri fills it straight
/// from the sentence.
struct VeyrnShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Add a task to \(.applicationName)",
                "Add to \(.applicationName)",
                "New \(.applicationName) task",
                "Have \(.applicationName) add a task",
                "Remind me in \(.applicationName)",
                "Add a task to \(\.$project) in \(.applicationName)",
            ],
            shortTitle: "Add Task",
            systemImageName: "plus.circle"
        )
    }
}
#endif
