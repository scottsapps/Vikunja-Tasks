import SwiftUI

/// Expandable inline editor that replaces a TaskRow when the task is tapped.
/// Saves on Esc, dismiss, or explicit Save. Sends only changed fields.
struct InlineTaskEditor: View {
    let task: VikunjaTask
    @Environment(TaskStore.self) private var store
    var onDelete: (() -> Void)? = nil
    var onDismiss: () -> Void

    // Editable field state — initialised from task
    @State private var title: String
    @State private var notesAttrStr: NSAttributedString
    @State private var richContext = RichTextContext()
    @State private var dueDate: Date?
    @State private var hasDueDate: Bool
    @State private var priority: Int          // 0 = none
    @State private var selectedLabelIds: Set<Int>
    @State private var selectedProjectId: Int
    @State private var reminderDate: Date
    @State private var hasReminder: Bool
    @State private var repeatAfter: Int?    // seconds; nil = no repeat
    @State private var repeatMode: Int?

    // UI state
    @State private var showingRepeatSheet = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var showDatePicker = false
    @State private var showReminderPicker = false
    @FocusState private var titleFocused: Bool

    // Subtask state
    @State private var loadedSubtasks: [VikunjaTask]? = nil
    @State private var newSubtaskTitle = ""
    @State private var isAddingSubtask = false

    init(task: VikunjaTask, onDelete: (() -> Void)? = nil, onDismiss: @escaping () -> Void) {
        self.task = task
        self.onDelete = onDelete
        self.onDismiss = onDismiss
        _title = State(initialValue: task.title)
        _notesAttrStr = State(initialValue: NSAttributedString())
        let due = task.effectiveDueDate
        _dueDate = State(initialValue: due)
        _hasDueDate = State(initialValue: due != nil)
        _priority = State(initialValue: task.priority ?? 0)
        _selectedLabelIds = State(initialValue: Set(task.labels?.map(\.id) ?? []))
        _selectedProjectId = State(initialValue: task.projectId)
        let firstReminder = task.reminders?.compactMap(\.date).first
        _hasReminder = State(initialValue: firstReminder != nil)
        _reminderDate = State(initialValue: firstReminder ?? Date())
        _repeatAfter = State(initialValue: task.repeatAfter.flatMap { $0 > 0 ? $0 : nil })
        _repeatMode = State(initialValue: task.repeatMode)
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
            RichTextToolbar(richContext: richContext)
            Divider()
            RichTextEditor(attributedText: $notesAttrStr, richContext: richContext)
                .frame(minHeight: 60, idealHeight: 80, maxHeight: 140)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

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
                    Divider().frame(height: 24)
                    repeatMenu
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

            // Subtasks section (lazy-loaded when editor opens)
            if let subtasks = loadedSubtasks {
                Divider()
                subtaskSection(subtasks)
            }

            Divider()

            // Action bar
            HStack(spacing: 12) {
                if let onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red.opacity(0.8))
                }

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
            // HTML parsing via WebKit must not run during a SwiftUI render pass —
            // doing so spins a nested CFRunLoop that lets state mutations fire mid-render,
            // triggering an AttributeGraph precondition failure (SIGABRT).
            notesAttrStr = RichTextUtils.attributedString(from: task.description ?? "")
            titleFocused = true
            // Lazy-load subtasks (single-task GET returns related_tasks; list endpoint doesn't).
            if task.id > 0, let full = try? await VikunjaAPI.fetchTask(id: task.id) {
                loadedSubtasks = full.subtasks
            } else {
                loadedSubtasks = task.subtasks.isEmpty ? [] : task.subtasks
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showDatePicker)
        .animation(.easeInOut(duration: 0.18), value: showReminderPicker)
        .sheet(isPresented: $showingRepeatSheet) {
            RepeatPickerSheet(repeatAfter: $repeatAfter, repeatMode: $repeatMode)
        }
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
                        systemImage: selectedProjectId == project.id ? "checkmark" : "folder"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
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
            ForEach(store.labels.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) { label in
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
                    let names = store.labels
                        .filter { selectedLabelIds.contains($0.id) }
                        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
                        .map(\.title)
                        .joined(separator: ", ")
                    Text(names)
                        .font(.system(size: 12))
                        .lineLimit(1)
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

    // MARK: - Repeat

    private var repeatMenu: some View {
        Button {
            showingRepeatSheet = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: repeatAfter != nil || repeatMode == 1 ? "repeat.circle.fill" : "repeat")
                    .font(.system(size: 12))
                Text(repeatLabel())
                    .font(.system(size: 12))
                    .foregroundStyle(repeatAfter != nil || repeatMode == 1 ? Color.accentColor : .secondary)
            }
            .padding(.horizontal, 10)
            .foregroundStyle(repeatAfter != nil || repeatMode == 1 ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func repeatLabel() -> String {
        if repeatMode == 1 { return "Monthly" }
        guard let ra = repeatAfter, ra > 0 else { return "Repeat" }
        let days = ra / 86_400
        switch days {
        case 1:   return "Daily"
        case 7:   return "Weekly"
        case 365: return "Yearly"
        default:
            if days % 7 == 0 { return "Every \(days / 7)w" }
            return "Every \(days)d"
        }
    }

    // MARK: - Subtasks

    private func subtaskSection(_ subtasks: [VikunjaTask]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SUBTASKS")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(subtasks, id: \.id) { sub in
                HStack(spacing: 8) {
                    Button {
                        completeSubtask(sub)
                    } label: {
                        Image(systemName: sub.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(sub.done ? Color.secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)

                    Text(sub.title)
                        .font(.system(size: 13))
                        .foregroundStyle(sub.done ? .secondary : .primary)
                        .strikethrough(sub.done, color: .secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }

            // Add subtask field
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                TextField("Add subtask…", text: $newSubtaskTitle)
                    .font(.system(size: 13))
                    .onSubmit { Task { await addSubtask() } }

                if isAddingSubtask {
                    ProgressView().controlSize(.mini)
                } else if !newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Add") { Task { await addSubtask() } }
                        .font(.system(size: 12))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func completeSubtask(_ subtask: VikunjaTask) {
        // Optimistically update the local list
        if var list = loadedSubtasks, let idx = list.firstIndex(where: { $0.id == subtask.id }) {
            list[idx].done.toggle()
            loadedSubtasks = list
        }
        Task {
            if subtask.done {
                try? await VikunjaAPI.reopenTask(id: subtask.id)
            } else {
                try? await VikunjaAPI.completeTask(id: subtask.id)
            }
        }
        VeyrnTelemetry.signal("TaskCompleted")
    }

    private func addSubtask() async {
        let title = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, task.id > 0 else { return }
        isAddingSubtask = true
        newSubtaskTitle = ""
        do {
            let newTask = try await VikunjaAPI.createTask(projectId: task.projectId, title: title)
            try await VikunjaAPI.addRelation(taskId: task.id, otherTaskId: newTask.id, kind: "subtask")
            loadedSubtasks = (loadedSubtasks ?? []) + [newTask]
            VeyrnTelemetry.signal("SubtaskAdded")
        } catch {
            // Restore title on failure
            newSubtaskTitle = title
        }
        isAddingSubtask = false
    }

    // MARK: - Save

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }

        isSaving = true
        var update = TaskUpdate()

        if trimmedTitle != task.title { update.title = trimmedTitle }

        let currentHTML = RichTextUtils.html(from: notesAttrStr)
        if currentHTML != (task.description ?? "") { update.description = currentHTML }

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

        let originalRepeat = task.repeatAfter.flatMap { $0 > 0 ? $0 : nil }
        let originalMode = task.repeatMode ?? 0
        let repeatChanged = (repeatAfter ?? 0) != (originalRepeat ?? 0) || (repeatMode ?? 0) != originalMode
        if repeatChanged {
            if let ra = repeatAfter, ra > 0 {
                update.repeatAfter = ra
                update.repeatMode = repeatMode ?? 0
            } else if repeatMode == 1 {
                update.repeatAfter = 30 * 86_400
                update.repeatMode = 1
            } else {
                update.clearRepeat = true
            }
        }

        // Only call API if something changed
        let hasChanges = update.title != nil || update.description != nil
            || update.dueDate != nil || update.clearDueDate
            || update.priority != nil || update.clearPriority
            || update.labelIds != nil || update.projectId != nil
            || update.reminders != nil || update.repeatAfter != nil || update.repeatMode != nil || update.clearRepeat

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

// MARK: - Repeat picker sheet

private enum RepeatUnit: String, CaseIterable {
    case days   = "Days"
    case weeks  = "Weeks"
    case months = "Months"
    case years  = "Years"
}

struct RepeatPickerSheet: View {
    @Binding var repeatAfter: Int?
    @Binding var repeatMode: Int?
    @Environment(\.dismiss) private var dismiss

    @State private var hasRepeat = false
    @State private var count = 1
    @State private var unit: RepeatUnit = .days
    @State private var fromCompletion = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Repeat", isOn: $hasRepeat.animation())
                }
                if hasRepeat {
                    Section {
                        Stepper(value: $count, in: 1...99) {
                            HStack {
                                Text("Every")
                                Text("\(count)")
                                    .fontWeight(.semibold)
                                    .monospacedDigit()
                                Text(unit == .months || unit == .years ? unit.rawValue.lowercased() : (count == 1 ? unit.rawValue.dropLast().lowercased() : unit.rawValue.lowercased()))
                            }
                        }
                        .disabled(unit == .months)
                        Picker("Unit", selection: $unit) {
                            ForEach(RepeatUnit.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    if unit != .months {
                        Section {
                            Toggle("From completion date", isOn: $fromCompletion)
                        } footer: {
                            Text(fromCompletion
                                 ? "Next due date is calculated from when you complete the task."
                                 : "Next due date is calculated from the original due date.")
                        }
                    }
                }
            }
            .navigationTitle("Repeat")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply(); dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .onAppear { loadFromBindings() }
    }

    private func loadFromBindings() {
        if repeatMode == 1 {
            hasRepeat = true
            unit = .months
            count = 1
            fromCompletion = false
            return
        }
        guard let ra = repeatAfter, ra > 0 else {
            hasRepeat = false
            return
        }
        hasRepeat = true
        fromCompletion = (repeatMode == 2)
        let days = ra / 86_400
        if days % 365 == 0 {
            unit = .years
            count = days / 365
        } else if days % 7 == 0 {
            unit = .weeks
            count = days / 7
        } else {
            unit = .days
            count = days
        }
    }

    private func apply() {
        guard hasRepeat else {
            repeatAfter = nil
            repeatMode = nil
            return
        }
        switch unit {
        case .days:
            repeatAfter = count * 86_400
            repeatMode = fromCompletion ? 2 : 0
        case .weeks:
            repeatAfter = count * 7 * 86_400
            repeatMode = fromCompletion ? 2 : 0
        case .months:
            repeatAfter = 30 * 86_400
            repeatMode = 1
        case .years:
            repeatAfter = count * 365 * 86_400
            repeatMode = fromCompletion ? 2 : 0
        }
    }
}
