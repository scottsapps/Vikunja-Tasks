import SwiftUI

// MARK: - Progress ring

private struct ProgressRing: View {
    let progress: Double
    let size: CGFloat
    let lineWidth: CGFloat
    @Environment(\.colorScheme) private var cs

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: min(1, CGFloat(progress)))
                    .stroke(fillColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
    }

    private var trackColor: Color {
        cs == .dark ? Color.white.opacity(0.16) : Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.14)
    }
    private var fillColor: Color {
        cs == .dark ? Color(red: 10/255, green: 132/255, blue: 255/255) : Color(red: 0, green: 122/255, blue: 255/255)
    }
}

// MARK: - InlineTaskEditor (Chips & Cards)

struct InlineTaskEditor: View {
    let task: VikunjaTask
    @Environment(TaskStore.self) private var store
    var onDelete: (() -> Void)? = nil
    var onDismiss: () -> Void

    @Environment(\.colorScheme) private var cs

    // Editable state
    @State private var title: String
    @State private var notesAttrStr: NSAttributedString
    /// What the import produced, plus whether the user has typed since. Together
    /// they let `save()` leave an untouched description completely alone.
    @State private var importedNotesAttrStr = NSAttributedString()
    @State private var notesEdited = false
    @State private var richContext = RichTextContext()
    @State private var dueDate: Date?
    @State private var hasDueDate: Bool
    @State private var priority: Int
    @State private var selectedLabelIds: Set<Int>
    @State private var selectedProjectId: Int
    @State private var reminderDate: Date
    @State private var hasReminder: Bool
    @State private var repeatAfter: Int?
    @State private var repeatMode: Int?

    // UI state
    @State private var showDatePicker = false
    @State private var showReminderPicker = false
    @State private var showingRepeatSheet = false
    @State private var showFormatting = false
    @State private var showLabelPicker = false
    @State private var isSaving = false

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

    // MARK: - Design tokens

    private var cardBg: Color { cs == .dark ? Color(red: 28/255, green: 28/255, blue: 30/255) : .white }
    private var insetBg: Color { cs == .dark ? Color(red: 42/255, green: 42/255, blue: 45/255) : Color(red: 245/255, green: 245/255, blue: 247/255) }
    private var primaryText: Color { cs == .dark ? Color(red: 242/255, green: 242/255, blue: 247/255) : Color(red: 28/255, green: 28/255, blue: 30/255) }
    private var mutedText: Color { cs == .dark ? Color(red: 134/255, green: 134/255, blue: 140/255) : Color(red: 138/255, green: 138/255, blue: 142/255) }
    private var hairline: Color { cs == .dark ? Color.white.opacity(0.10) : Color(red: 60/255, green: 60/255, blue: 67/255).opacity(0.10) }
    private var circleStroke: Color { cs == .dark ? Color(red: 85/255, green: 85/255, blue: 92/255) : Color(red: 202/255, green: 202/255, blue: 208/255) }
    private var accentBlue: Color { cs == .dark ? Color(red: 10/255, green: 132/255, blue: 255/255) : Color(red: 0, green: 122/255, blue: 255/255) }

    // Chip palette
    private var dueBg: Color    { cs == .dark ? Color(red: 10/255,  green: 132/255, blue: 255/255).opacity(0.18) : Color(red: 231/255, green: 240/255, blue: 255/255) }
    private var dueFg: Color    { cs == .dark ? Color(red: 90/255,  green: 169/255, blue: 255/255) : Color(red: 31/255,  green: 111/255, blue: 224/255) }
    private var remBg: Color    { cs == .dark ? Color(red: 255/255, green: 159/255, blue: 10/255 ).opacity(0.18) : Color(red: 255/255, green: 241/255, blue: 221/255) }
    private var remFg: Color    { cs == .dark ? Color(red: 242/255, green: 169/255, blue: 59/255 ) : Color(red: 185/255, green: 107/255, blue: 0) }
    private var repBg: Color    { cs == .dark ? Color(red: 48/255,  green: 209/255, blue: 88/255 ).opacity(0.18) : Color(red: 226/255, green: 246/255, blue: 232/255) }
    private var repFg: Color    { cs == .dark ? Color(red: 79/255,  green: 208/255, blue: 106/255) : Color(red: 30/255,  green: 142/255, blue: 64/255 ) }
    private var priNeutralBg: Color { cs == .dark ? Color(red: 120/255, green: 120/255, blue: 128/255).opacity(0.24) : Color(red: 239/255, green: 239/255, blue: 242/255) }
    private var priNeutralFg: Color { cs == .dark ? Color(red: 166/255, green: 166/255, blue: 172/255) : Color(red: 124/255, green: 124/255, blue: 130/255) }
    private var addBorder: Color { cs == .dark ? Color(red: 74/255, green: 74/255, blue: 78/255) : Color(red: 205/255, green: 205/255, blue: 211/255) }
    private var addFg: Color    { cs == .dark ? Color(red: 134/255, green: 134/255, blue: 140/255) : Color(red: 154/255, green: 154/255, blue: 160/255) }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                notesBlock.padding(.top, 16)
                chipsSection.padding(.top, 14)
                if let subtasks = loadedSubtasks {
                    subtasksCard(subtasks).padding(.top, 16)
                }
                hairline.frame(height: 1).padding(.top, 16)
                footerRow.padding(.top, 15)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .background(cardBg)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 520)
        #endif
        .task {
            DiagnosticLog.info("editor open task \(task.id)")
            DiagnosticLog.breadcrumb("editor.open")

            // WebKit HTML parsing must not run during a SwiftUI render pass.
            DiagnosticLog.breadcrumb("editor.htmlImport")
            let html = task.description ?? ""
            let importStart = Date()
            notesAttrStr = RichTextUtils.attributedString(from: html)
            importedNotesAttrStr = notesAttrStr
            let importElapsed = Date().timeIntervalSince(importStart)
            let imgCount = html.components(separatedBy: "<img").count - 1
            DiagnosticLog.info("html import: \(html.utf8.count) bytes → \(String(format: "%.2f", importElapsed)) s; img tags \(imgCount) (absolute \(absoluteImgTagCount(html)))")
            DiagnosticLog.breadcrumb("idle")

            DiagnosticLog.breadcrumb("editor.subtaskFetch")
            let subtaskStart = Date()
            if task.id > 0, let full = try? await VikunjaAPI.fetchTask(id: task.id) {
                loadedSubtasks = full.subtasks
            } else {
                loadedSubtasks = task.subtasks.isEmpty ? [] : task.subtasks
            }
            let subtaskElapsed = Date().timeIntervalSince(subtaskStart)
            DiagnosticLog.info("subtask fetch task \(task.id) → \(loadedSubtasks?.count ?? 0) subtasks, \(String(format: "%.1f", subtaskElapsed)) s")
            DiagnosticLog.breadcrumb("idle")
        }
        .animation(.easeInOut(duration: 0.2), value: showDatePicker)
        .animation(.easeInOut(duration: 0.2), value: showReminderPicker)
        .animation(.easeInOut(duration: 0.2), value: showFormatting)
        .sheet(isPresented: $showingRepeatSheet) {
            RepeatPickerSheet(repeatAfter: $repeatAfter, repeatMode: $repeatMode)
        }
        .sheet(isPresented: $showLabelPicker) {
            labelPickerSheet
        }
    }

    // MARK: - Title row

    private var titleRow: some View {
        HStack(alignment: .top, spacing: 13) {
            Button {
                let t = task
                Task {
                    if t.done { await store.reopen(task: t) }
                    else { await store.complete(task: t) }
                }
                onDismiss()
            } label: {
                Circle()
                    .stroke(circleStroke, lineWidth: 2)
                    .frame(width: 25, height: 25)
                    // A stroked Circle only hit-tests on the ring itself; on macOS
                    // the pointer is exact, so the interior would be dead.
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 5)

            VStack(alignment: .leading, spacing: 10) {
                #if os(macOS)
                // NSViewRepresentable so we can set selectsAllOnBeginEditing = false,
                // preventing macOS from highlighting all text when the sheet opens.
                MacTitleTextField(text: $title)
                #else
                TextField("Task title", text: $title, axis: .vertical)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1...5)
                    .tracking(-0.5)
                #endif

                projectPill
            }
        }
    }

    private var projectPill: some View {
        let project = store.projects.first { $0.id == selectedProjectId }
        let base = Color(vikunjaHex: project?.hexColor) ?? Color(red: 107/255, green: 78/255, blue: 230/255)
        let bg = cs == .dark ? base.opacity(0.20) : base.opacity(0.12)
        let fg = cs == .dark ? base.opacity(0.90) : base

        return Menu {
            ForEach(store.projects) { proj in
                Button {
                    selectedProjectId = proj.id
                } label: {
                    Label(proj.title, systemImage: selectedProjectId == proj.id ? "checkmark" : "folder")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill").font(.system(size: 14))
                Text(project?.title ?? "Project").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(fg)
            .padding(.leading, 9).padding(.trailing, 11).padding(.vertical, 4)
            .background(bg)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Notes block

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showFormatting {
                RichTextToolbar(richContext: richContext)
                    .padding(.bottom, 8)
            }
            RichTextEditor(attributedText: $notesAttrStr, richContext: richContext,
                           onUserEdit: { notesEdited = true })
                .frame(minHeight: 60, idealHeight: 90, maxHeight: 180)
                .padding(.trailing, 42)
        }
        .padding(15)
        .overlay(alignment: .topTrailing) {
            Button {
                showFormatting.toggle()
            } label: {
                Text("Aa")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(cs == .dark ? Color(red: 198/255, green: 198/255, blue: 204/255) : Color(red: 108/255, green: 108/255, blue: 114/255))
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(cs == .dark ? Color(red: 58/255, green: 58/255, blue: 62/255) : .white)
                            .shadow(color: .black.opacity(cs == .dark ? 0 : 0.10), radius: 1.5, y: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(11)
        }
        .background(insetBg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Property chips

    private var chipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(hSpacing: 8, vSpacing: 8) {
                if hasDueDate, let d = dueDate {
                    chip(icon: "calendar", label: dateChipLabel(d), bg: dueBg, fg: dueFg) {
                        withAnimation { showDatePicker.toggle(); showReminderPicker = false }
                    }
                    .contextMenu {
                        Button("Clear due date", role: .destructive) {
                            hasDueDate = false; dueDate = nil
                            withAnimation { showDatePicker = false }
                        }
                    }
                }

                if hasReminder {
                    chip(icon: "bell", label: reminderChipLabel(), bg: remBg, fg: remFg) {
                        withAnimation { showReminderPicker.toggle(); showDatePicker = false }
                    }
                    .contextMenu {
                        Button("Clear reminder", role: .destructive) {
                            hasReminder = false
                            withAnimation { showReminderPicker = false }
                        }
                    }
                }

                if repeatAfter != nil || repeatMode == 1 {
                    chip(icon: "repeat", label: repeatChipLabel(), bg: repBg, fg: repFg) {
                        showingRepeatSheet = true
                    }
                    .contextMenu {
                        Button("Clear repeat", role: .destructive) {
                            repeatAfter = nil; repeatMode = nil
                        }
                    }
                }

                if priority > 0 {
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
                        chipLabel(icon: "flag", label: priorityLabel(priority), bg: priorityChipBg(priority), fg: priorityChipFg(priority))
                    }
                    .buttonStyle(.plain)
                }

                ForEach(selectedLabels, id: \.id) { label in
                    let base = Color(vikunjaHex: label.hexColor)
                    let bg = base.map { cs == .dark ? $0.opacity(0.20) : $0.opacity(0.15) }
                        ?? (cs == .dark ? dueBg : dueBg)
                    let fg = base ?? (cs == .dark ? dueFg : dueFg)
                    chip(icon: "tag", label: label.title, bg: bg, fg: fg) {
                        showLabelPicker = true
                    }
                }

                addChip
            }

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
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showReminderPicker {
                DatePicker(
                    "Remind me at",
                    selection: $reminderDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .padding(.horizontal, 4).padding(.vertical, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var selectedLabels: [VikunjaLabel] {
        store.labels
            .filter { selectedLabelIds.contains($0.id) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    // MARK: - Chip building helpers

    @ViewBuilder
    private func chip(icon: String, label: String, bg: Color, fg: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            chipLabel(icon: icon, label: label, bg: bg, fg: fg)
        }
        .buttonStyle(.plain)
    }

    private func chipLabel(icon: String, label: String, bg: Color, fg: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 15))
            Text(label).font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 13)
        .frame(height: 33)
        .background(bg)
        .clipShape(Capsule())
    }

    private var addChip: some View {
        Menu {
            if !hasDueDate {
                Button("Due Date") {
                    hasDueDate = true
                    dueDate = VikunjaAPI.applyDefaultTime(Date())
                    withAnimation { showDatePicker = true }
                }
            }
            if !hasReminder {
                Button("Reminder") {
                    hasReminder = true
                    reminderDate = defaultReminderDate()
                    withAnimation { showReminderPicker = true }
                }
            }
            if repeatAfter == nil && repeatMode != 1 {
                Button("Repeat") { showingRepeatSheet = true }
            }
            if priority == 0 {
                Button("Priority") { priority = 1 }
            }
            Button("Label") { showLabelPicker = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 15))
                Text("Add").font(.system(size: 14, weight: .medium))
            }
            .foregroundStyle(addFg)
            .padding(.horizontal, 13)
            .frame(height: 33)
            .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [5, 3])).foregroundStyle(addBorder))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Priority chip colors

    private func priorityChipBg(_ p: Int) -> Color {
        switch p {
        case 4, 5: return cs == .dark ? Color.red.opacity(0.18) : Color.red.opacity(0.10)
        case 3:    return cs == .dark ? Color.orange.opacity(0.18) : Color.orange.opacity(0.10)
        case 2:    return cs == .dark ? Color.yellow.opacity(0.20) : Color.yellow.opacity(0.10)
        default:   return priNeutralBg
        }
    }

    private func priorityChipFg(_ p: Int) -> Color {
        switch p {
        case 4, 5: return cs == .dark ? Color(red: 255/255, green: 99/255, blue: 90/255) : .red
        case 3:    return cs == .dark ? Color(red: 255/255, green: 159/255, blue: 60/255) : .orange
        case 2:    return cs == .dark ? Color(red: 255/255, green: 220/255, blue: 80/255) : Color(red: 153/255, green: 122/255, blue: 0)
        default:   return priNeutralFg
        }
    }

    // MARK: - Subtasks card

    private func subtasksCard(_ subtasks: [VikunjaTask]) -> some View {
        let done = subtasks.filter(\.done).count
        let total = subtasks.count
        let progress = total > 0 ? Double(done) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProgressRing(progress: progress, size: 22, lineWidth: 2.5)
                Text("Subtasks")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(primaryText)
                Spacer()
                Text("\(done) of \(total)")
                    .font(.system(size: 13))
                    .foregroundStyle(mutedText)
            }
            .padding(.bottom, 12)

            ForEach(subtasks, id: \.id) { sub in
                HStack(spacing: 11) {
                    Button { completeSubtask(sub) } label: {
                        ZStack {
                            if sub.done {
                                Circle().fill(accentBlue).frame(width: 21, height: 21)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Circle()
                                    .stroke(circleStroke, lineWidth: 1.8)
                                    .frame(width: 21, height: 21)
                            }
                        }
                        .frame(width: 21, height: 21)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Text(sub.title)
                        .font(.system(size: 15))
                        .foregroundStyle(sub.done ? Color(red: 103/255, green: 103/255, blue: 110/255) : primaryText)
                        .strikethrough(sub.done, color: Color(red: 103/255, green: 103/255, blue: 110/255))
                        .lineLimit(2)
                }
                .padding(.vertical, 6)
            }

            HStack(spacing: 11) {
                ZStack {
                    Circle().stroke(mutedText, lineWidth: 1.5).frame(width: 21, height: 21)
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(mutedText)
                }
                TextField("Add subtask…", text: $newSubtaskTitle)
                    .font(.system(size: 15))
                    .foregroundStyle(mutedText)
                    .onSubmit { Task { await addSubtask() } }
                if isAddingSubtask {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(insetBg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 0) {
            if let onDelete {
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 18))
                        .foregroundStyle(cs == .dark ? Color(red: 255/255, green: 69/255, blue: 58/255) : Color(red: 255/255, green: 59/255, blue: 48/255))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, -6)
            }

            Spacer()

            Button("Cancel") {
                DiagnosticLog.info("editor dismissed (cancelled)")
                onDismiss()
            }
                .font(.system(size: 16))
                .foregroundStyle(accentBlue)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

            Button {
                Task { await save() }
            } label: {
                Group {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 10)
            }
            .background(
                Capsule()
                    .fill(accentBlue)
                    .shadow(color: accentBlue.opacity(cs == .dark ? 0.40 : 0.35), radius: 8, y: 6)
            )
            .buttonStyle(.plain)
            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Label picker sheet

    private var labelPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(store.labels.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) { label in
                    Button {
                        if selectedLabelIds.contains(label.id) {
                            selectedLabelIds.remove(label.id)
                        } else {
                            selectedLabelIds.insert(label.id)
                        }
                    } label: {
                        HStack {
                            let isSelected = selectedLabelIds.contains(label.id)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            Text(label.title).foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
                if store.labels.isEmpty {
                    Text("No labels yet").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Labels")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showLabelPicker = false }.fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Chip label helpers

    private func dateChipLabel(_ date: Date) -> String {
        DayLabel.compact(date)
    }

    private func reminderChipLabel() -> String {
        let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
        return fmt.string(from: reminderDate)
    }

    private func repeatChipLabel() -> String {
        if repeatMode == 1 { return "Monthly" }
        guard let ra = repeatAfter, ra > 0 else { return "Repeat" }
        let days = ra / 86_400
        switch days {
        case 1: return "Daily"; case 7: return "Weekly"; case 365: return "Yearly"
        default: return days % 7 == 0 ? "Every \(days / 7)w" : "Every \(days)d"
        }
    }

    private func defaultReminderDate() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        if let due = dueDate {
            var comps = cal.dateComponents([.year, .month, .day], from: due)
            comps.hour = 8; comps.minute = 0; comps.second = 0
            comps.timeZone = cal.timeZone
            return cal.date(from: comps) ?? due
        } else {
            var comps = cal.dateComponents([.year, .month, .day], from: Date())
            comps.day = (comps.day ?? 0) + 1
            comps.hour = 9; comps.minute = 0; comps.second = 0
            comps.timeZone = cal.timeZone
            return cal.date(from: comps) ?? Date()
        }
    }

    // MARK: - Subtask actions

    private func completeSubtask(_ subtask: VikunjaTask) {
        if var list = loadedSubtasks, let idx = list.firstIndex(where: { $0.id == subtask.id }) {
            list[idx].done.toggle()
            loadedSubtasks = list
        }
        Task {
            do {
                if subtask.done {
                    try await VikunjaAPI.reopenTask(id: subtask.id)
                } else {
                    try await VikunjaAPI.completeTask(id: subtask.id)
                    VeyrnTelemetry.signal("TaskCompleted")
                }
            } catch {
                // revert the optimistic flip
                if var list = loadedSubtasks,
                   let idx = list.firstIndex(where: { $0.id == subtask.id }) {
                    list[idx].done = subtask.done
                    loadedSubtasks = list
                }
            }
        }
    }

    private func addSubtask() async {
        let t = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, task.id > 0 else { return }
        isAddingSubtask = true
        newSubtaskTitle = ""
        do {
            let newTask = try await VikunjaAPI.createTask(projectId: task.projectId, title: t)
            try await VikunjaAPI.addRelation(taskId: task.id, otherTaskId: newTask.id, kind: "subtask")
            loadedSubtasks = (loadedSubtasks ?? []) + [newTask]
            VeyrnTelemetry.signal("SubtaskAdded")
        } catch {
            newSubtaskTitle = t
        }
        isAddingSubtask = false
    }

    // MARK: - Save

    private func save() async {
        DiagnosticLog.breadcrumb("editor.save")
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        isSaving = true
        var update = TaskUpdate()
        var changedFields: [String] = []

        if trimmedTitle != task.title { update.title = trimmedTitle; changedFields.append("title") }

        // Only write the description back if the user actually edited it. Our HTML
        // and the server's never match byte for byte, so comparing the two would
        // rewrite every description on every save — degrading anything we can't
        // round-trip (images especially) on notes the user only looked at.
        let exportStart = Date()
        let currentHTML = notesEdited ? RichTextUtils.html(from: notesAttrStr) : (task.description ?? "")
        let exportElapsed = Date().timeIntervalSince(exportStart)
        // Second gate: typing something and undoing it shouldn't rewrite anything.
        let descriptionChanged = notesEdited
            && currentHTML != RichTextUtils.html(from: importedNotesAttrStr)
        if descriptionChanged { update.description = currentHTML; changedFields.append("description") }
        DiagnosticLog.info("html export: \(currentHTML.utf8.count) bytes, \(String(format: "%.2f", exportElapsed)) s, edited=\(notesEdited ? "yes" : "no"), changed=\(descriptionChanged ? "yes" : "no")")

        let originalDue = task.effectiveDueDate
        if !hasDueDate && originalDue != nil {
            update.clearDueDate = true
            changedFields.append("dueDate")
        } else if hasDueDate, let d = dueDate {
            let cal = Calendar.current
            if originalDue == nil || !cal.isDate(d, inSameDayAs: originalDue!) {
                update.dueDate = VikunjaAPI.applyDefaultTime(d)
                changedFields.append("dueDate")
            }
        }

        let originalPriority = task.priority ?? 0
        if priority != originalPriority {
            if priority == 0 { update.clearPriority = true } else { update.priority = priority }
            changedFields.append("priority")
        }

        let originalLabelIds = Set(task.labels?.map(\.id) ?? [])
        if selectedLabelIds != originalLabelIds {
            update.labelIds = Array(selectedLabelIds)
            changedFields.append("labels")
        }

        if selectedProjectId != task.projectId {
            update.projectId = selectedProjectId
            changedFields.append("project")
        }

        let originalReminder = task.reminders?.compactMap(\.date).first
        let reminderChanged = hasReminder != (originalReminder != nil)
            || (hasReminder && reminderDate != originalReminder)
        if reminderChanged {
            update.reminders = hasReminder ? [reminderDate] : []
            changedFields.append("reminders")
        }

        let originalRepeat = task.repeatAfter.flatMap { $0 > 0 ? $0 : nil }
        let originalMode = task.repeatMode ?? 0
        if (repeatAfter ?? 0) != (originalRepeat ?? 0) || (repeatMode ?? 0) != originalMode {
            if let ra = repeatAfter, ra > 0 {
                update.repeatAfter = ra
                update.repeatMode = repeatMode ?? 0
            } else if repeatMode == 1 {
                update.repeatAfter = 30 * 86_400
                update.repeatMode = 1
            } else {
                update.clearRepeat = true
            }
            changedFields.append("repeat")
        }

        let hasChanges = update.title != nil || update.description != nil
            || update.dueDate != nil || update.clearDueDate
            || update.priority != nil || update.clearPriority
            || update.labelIds != nil || update.projectId != nil
            || update.reminders != nil || update.repeatAfter != nil
            || update.repeatMode != nil || update.clearRepeat

        if hasChanges {
            DiagnosticLog.info("save task \(task.id): fields [\(changedFields.joined(separator: ", "))]")
            await store.update(taskId: task.id, with: update)
        }
        DiagnosticLog.info("editor dismissed (saved)")
        DiagnosticLog.breadcrumb("idle")
        onDismiss()
        isSaving = false
    }

    private func absoluteImgTagCount(_ html: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: "<img[^>]*src=[\"']https?://", options: .caseInsensitive) else { return 0 }
        let range = NSRange(html.startIndex..., in: html)
        return regex.numberOfMatches(in: html, range: range)
    }

    // MARK: - Helpers

    private func priorityLabel(_ p: Int) -> String {
        switch p {
        case 1: return "Low"; case 2: return "Medium"; case 3: return "High"
        case 4: return "Urgent"; case 5: return "Critical"; default: return "None"
        }
    }
}

// MARK: - macOS title field (prevents select-all on focus)

#if os(macOS)
private final class NonSelectingNSTextField: NSTextField {
    // macOS calls selectText(_:) when a text field becomes key; overriding it
    // lets us redirect to a cursor-at-end placement instead of select-all.
    override func selectText(_ sender: Any?) {
        super.selectText(sender)
        if let editor = currentEditor() as? NSTextView {
            let end = (stringValue as NSString).length
            editor.selectedRange = NSRange(location: end, length: 0)
        }
    }
}

private struct MacTitleTextField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NonSelectingNSTextField {
        let tf = NonSelectingNSTextField()
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.isEditable = true
        tf.isSelectable = true
        tf.font = .systemFont(ofSize: 23, weight: .bold)
        tf.textColor = .labelColor
        tf.focusRingType = .none
        tf.usesSingleLineMode = false
        tf.cell?.wraps = true
        tf.cell?.isScrollable = false
        tf.lineBreakMode = .byWordWrapping
        tf.placeholderString = "Task title"
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NonSelectingNSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
        nsView.textColor = .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NonSelectingNSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        nsView.preferredMaxLayoutWidth = width
        let height = nsView.intrinsicContentSize.height
        return CGSize(width: width, height: max(height, 28))
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var binding: Binding<String>
        init(binding: Binding<String>) { self.binding = binding }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField { binding.wrappedValue = tf.stringValue }
        }
    }
}
#endif

// MARK: - Repeat picker sheet (unchanged)

private enum RepeatUnit: String, CaseIterable {
    case days = "Days", weeks = "Weeks", months = "Months", years = "Years"
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
                                Text("\(count)").fontWeight(.semibold).monospacedDigit()
                                Text(unitLabel)
                            }
                        }
                        .disabled(unit == .months)
                        Picker("Unit", selection: $unit) {
                            ForEach(RepeatUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply(); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onAppear { loadFromBindings() }
    }

    private var unitLabel: String {
        switch unit {
        case .months, .years: return unit.rawValue.lowercased()
        default: return count == 1 ? String(unit.rawValue.dropLast()).lowercased() : unit.rawValue.lowercased()
        }
    }

    private func loadFromBindings() {
        if repeatMode == 1 { hasRepeat = true; unit = .months; count = 1; fromCompletion = false; return }
        guard let ra = repeatAfter, ra > 0 else { hasRepeat = true; return }
        hasRepeat = true
        fromCompletion = (repeatMode == 2)
        let days = ra / 86_400
        if days % 365 == 0 { unit = .years; count = days / 365 }
        else if days % 7 == 0 { unit = .weeks; count = days / 7 }
        else { unit = .days; count = days }
    }

    private func apply() {
        guard hasRepeat else { repeatAfter = nil; repeatMode = nil; return }
        switch unit {
        case .days:   repeatAfter = count * 86_400;       repeatMode = fromCompletion ? 2 : 0
        case .weeks:  repeatAfter = count * 7 * 86_400;   repeatMode = fromCompletion ? 2 : 0
        case .months: repeatAfter = 30 * 86_400;          repeatMode = 1
        case .years:  repeatAfter = count * 365 * 86_400; repeatMode = fromCompletion ? 2 : 0
        }
    }
}
