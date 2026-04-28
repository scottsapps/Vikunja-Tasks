import SwiftUI

/// Expandable inline editor that replaces a TaskRow when the task is tapped.
/// Saves on Esc, dismiss, or explicit Save. Sends only changed fields.
struct InlineTaskEditor: View {
    let task: VikunjaTask
    @Environment(TaskStore.self) private var store
    var onDismiss: () -> Void

    // Editable field state — initialised from task
    @State private var title: String
    @State private var notes: String
    @State private var dueDate: Date?
    @State private var hasDueDate: Bool
    @State private var priority: Int          // 0 = none
    @State private var selectedLabelIds: Set<Int>
    @State private var selectedProjectId: Int
    @State private var reminderDate: Date
    @State private var hasReminder: Bool

    // UI state
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDatePicker = false
    @State private var showReminderPicker = false
    @FocusState private var titleFocused: Bool

    init(task: VikunjaTask, onDismiss: @escaping () -> Void) {
        self.task = task
        self.onDismiss = onDismiss
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.description ?? "")
        let due = task.effectiveDueDate
        _dueDate = State(initialValue: due)
        _hasDueDate = State(initialValue: due != nil)
        _priority = State(initialValue: task.priority ?? 0)
        _selectedLabelIds = State(initialValue: Set(task.labels?.map(\.id) ?? []))
        _selectedProjectId = State(initialValue: task.projectId)
        let firstReminder = task.reminders?.compactMap(\.date).first
        _hasReminder = State(initialValue: firstReminder != nil)
        _reminderDate = State(initialValue: firstReminder ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            TextField("Task title", text: $title, axis: .vertical)
                .font(.system(size: 14, weight: .medium))
                .focused($titleFocused)
                .lineLimit(1...3)
                .padding(.horizontal, 12)
                .padding(.top, 10)

            Divider().padding(.top, 6)

            // Notes
            TextField("Notes", text: $notes, axis: .vertical)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Metadata row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    dueDateButton
                    Divider().frame(height: 24)
                    priorityMenu
                    Divider().frame(height: 24)
                    projectMenu
                    Divider().frame(height: 24)
                    labelsMenu
                    Divider().frame(height: 24)
                    reminderButton
                }
            }
            .frame(height: 38)

            if showDatePicker {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { dueDate ?? Date() },
                        set: { dueDate = $0; hasDueDate = true }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showReminderPicker {
                DatePicker(
                    "Remind me at",
                    selection: $reminderDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            // Action bar
            HStack(spacing: 12) {
                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") {
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.escape, modifiers: [])

                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1.5)
        )
        .task {
            titleFocused = true
        }
        .animation(.easeInOut(duration: 0.18), value: showDatePicker)
        .animation(.easeInOut(duration: 0.18), value: showReminderPicker)
    }

    // MARK: - Due date

    private var dueDateButton: some View {
        Button {
            if hasDueDate {
                showDatePicker.toggle()
            } else {
                hasDueDate = true
                dueDate = VikunjaAPI.applyDefaultTime(Date())
                showDatePicker = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: hasDueDate ? "calendar.badge.checkmark" : "calendar")
                    .font(.system(size: 12))
                if hasDueDate, let d = dueDate {
                    Text(d, style: .date)
                        .font(.system(size: 12))
                } else {
                    Text("Due date")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(hasDueDate ? Color.accentColor : .secondary)
        .contextMenu {
            if hasDueDate {
                Button("Clear due date", role: .destructive) {
                    hasDueDate = false
                    dueDate = nil
                    showDatePicker = false
                }
            }
        }
    }

    // MARK: - Priority

    private var priorityMenu: some View {
        Menu {
            Button("None") { priority = 0 }
            Divider()
            ForEach(1...5, id: \.self) { p in
                Button {
                    priority = p
                } label: {
                    Label(priorityLabel(p), systemImage: priority == p ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: priority > 0 ? "flag.fill" : "flag")
                    .font(.system(size: 12))
                    .foregroundStyle(priority > 0 ? priorityColor(priority) : .secondary)
                if priority > 0 {
                    Text(priorityLabel(priority))
                        .font(.system(size: 12))
                        .foregroundStyle(priorityColor(priority))
                } else {
                    Text("Priority")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Project

    private var projectMenu: some View {
        Menu {
            ForEach(store.projects) { project in
                Button {
                    selectedProjectId = project.id
                } label: {
                    Label(
                        project.title,
                        systemImage: selectedProjectId == project.id ? "checkmark.circle.fill" : "circle.dashed"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.dashed")
                    .font(.system(size: 12))
                Text(store.projectMap[selectedProjectId] ?? "Project")
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Labels

    private var labelsMenu: some View {
        Menu {
            ForEach(store.labels) { label in
                Button {
                    if selectedLabelIds.contains(label.id) {
                        selectedLabelIds.remove(label.id)
                    } else {
                        selectedLabelIds.insert(label.id)
                    }
                } label: {
                    Label(
                        label.title,
                        systemImage: selectedLabelIds.contains(label.id) ? "checkmark" : ""
                    )
                }
            }
            if store.labels.isEmpty {
                Text("No labels yet")
                    .foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedLabelIds.isEmpty ? "tag" : "tag.fill")
                    .font(.system(size: 12))
                if !selectedLabelIds.isEmpty {
                    Text("\(selectedLabelIds.count)")
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 10)
            .foregroundStyle(selectedLabelIds.isEmpty ? .secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reminder button

    private var reminderButton: some View {
        Button {
            if hasReminder {
                showReminderPicker.toggle()
            } else {
                hasReminder = true
                // Default: due date at 8 AM Eastern, or tomorrow 9 AM if no due date
                if let due = dueDate {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = TimeZone(identifier: "America/New_York")!
                    var comps = cal.dateComponents([.year, .month, .day], from: due)
                    comps.hour = 8; comps.minute = 0; comps.second = 0
                    comps.timeZone = TimeZone(identifier: "America/New_York")!
                    reminderDate = cal.date(from: comps) ?? due
                } else {
                    var cal = Calendar(identifier: .gregorian)
                    cal.timeZone = TimeZone(identifier: "America/New_York")!
                    var comps = cal.dateComponents([.year, .month, .day], from: Date())
                    comps.day! += 1; comps.hour = 9; comps.minute = 0; comps.second = 0
                    comps.timeZone = TimeZone(identifier: "America/New_York")!
                    reminderDate = cal.date(from: comps) ?? Date()
                }
                showReminderPicker = true
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: hasReminder ? "bell.fill" : "bell")
                    .font(.system(size: 12))
                if hasReminder {
                    Text(reminderDate, style: .date)
                        .font(.system(size: 12))
                    Text(reminderDate, style: .time)
                        .font(.system(size: 12))
                } else {
                    Text("Remind me")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .foregroundStyle(hasReminder ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if hasReminder {
                Button("Clear reminder", role: .destructive) {
                    hasReminder = false
                    showReminderPicker = false
                }
            }
        }
    }

    // MARK: - Save

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        var update = TaskUpdate()

        if trimmedTitle != task.title { update.title = trimmedTitle }

        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedNotes != (task.description ?? "") { update.description = trimmedNotes }

        let originalDue = task.effectiveDueDate
        if !hasDueDate && originalDue != nil {
            update.clearDueDate = true
        } else if hasDueDate, let d = dueDate {
            update.dueDate = VikunjaAPI.applyDefaultTime(d)
        }

        let originalPriority = task.priority ?? 0
        if priority != originalPriority {
            if priority == 0 { update.clearPriority = true }
            else { update.priority = priority }
        }

        let originalLabelIds = Set(task.labels?.map(\.id) ?? [])
        if selectedLabelIds != originalLabelIds {
            update.labelIds = Array(selectedLabelIds)
        }

        if selectedProjectId != task.projectId {
            update.projectId = selectedProjectId
        }

        let originalReminder = task.reminders?.compactMap(\.date).first
        let reminderChanged = hasReminder != (originalReminder != nil)
            || (hasReminder && reminderDate != originalReminder)
        if reminderChanged {
            update.reminders = hasReminder ? [reminderDate] : []
        }

        // Only call API if something changed
        let hasChanges = update.title != nil || update.description != nil
            || update.dueDate != nil || update.clearDueDate
            || update.priority != nil || update.clearPriority
            || update.labelIds != nil || update.projectId != nil
            || update.reminders != nil

        if hasChanges {
            await store.update(taskId: task.id, with: update)
        }
        onDismiss()

        isSaving = false
    }

    // MARK: - Helpers

    private func priorityLabel(_ p: Int) -> String {
        switch p {
        case 1: return "Low"
        case 2: return "Medium"
        case 3: return "High"
        case 4: return "Urgent"
        case 5: return "Critical"
        default: return "None"
        }
    }

    private func priorityColor(_ p: Int) -> Color {
        switch p {
        case 1: return .blue
        case 2: return .yellow
        case 3: return .orange
        case 4, 5: return .red
        default: return .secondary
        }
    }
}
