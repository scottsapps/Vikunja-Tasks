import SwiftUI

struct QuickAddSheet: View {
    var store: TaskStore
    var onExpandToggle: ((Bool) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var cs

    @State private var inputText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    // Expanded toggle
    @State private var isExpanded = false

    // Expanded metadata
    @State private var expandedHasDueDate = false
    @State private var expandedDueDate: Date? = nil
    @State private var expandedPriority: Int = 0
    @State private var expandedProjectId: Int? = nil
    @State private var expandedLabelIds: Set<Int> = []
    @State private var expandedNotes = ""
    @State private var expandedRepeatAfter: Int? = nil
    @State private var expandedRepeatMode: Int? = nil
    @State private var expandedHasReminder = false
    @State private var expandedReminderDate = Date()
    @State private var showExpandedReminderPicker = false

    // Subtasks
    @State private var subtaskTitles: [String] = []
    @State private var newSubtaskTitle = ""

    // UI state
    @State private var showExpandedDatePicker = false
    @State private var showingRepeatSheet = false
    @State private var showLabelPicker = false

    private var parsed: QuickAddResult {
        QuickAddParser.parse(inputText, knownProjects: store.projects, knownLabels: store.labels)
    }

    /// True when the parsed input would actually render at least one preview chip.
    /// Keeps the footer from shifting for input that parses to nothing.
    private var hasPreviewContent: Bool {
        let p = parsed
        return p.dueDate != nil
            || p.priority != nil
            || !p.labelTitles.isEmpty
            || p.projectName != nil
            || p.repeatAfter != nil
    }

    // MARK: - Design tokens

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
            VStack(alignment: .leading, spacing: 16) {
                // Heading row
                HStack {
                    Text("New Task")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Spacer()
                    Button {
                        toggleExpand()
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up.circle" : "chevron.down.circle")
                            .font(.system(size: 18))
                            .foregroundStyle(isExpanded ? accentBlue : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse" : "More options")
                }

                // Quick-add input
                TextField("Buy milk *groceries +Home !2 tomorrow", text: $inputText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 15))
                    .focused($fieldFocused)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.sentences)
                    #endif
                    .onSubmit { submit() }

                // Live preview chips (collapsed only)
                if hasPreviewContent && !isExpanded {
                    previewRow
                }

                // Expanded section
                if isExpanded {
                    expandedSection
                }

                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                // Footer
                hairline.frame(height: 1)
                footerRow
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
        }
        .onAppear { fieldFocused = true }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.18), value: hasPreviewContent)
        .animation(.easeInOut(duration: 0.2), value: showExpandedDatePicker)
        .animation(.easeInOut(duration: 0.2), value: showExpandedReminderPicker)
        .sheet(isPresented: $showingRepeatSheet) {
            RepeatPickerSheet(repeatAfter: $expandedRepeatAfter, repeatMode: $expandedRepeatMode)
        }
        .sheet(isPresented: $showLabelPicker) {
            labelPickerSheet
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 520)
        #endif
    }

    // MARK: - Expand toggle

    private func toggleExpand() {
        if !isExpanded {
            let p = parsed
            expandedHasDueDate = p.dueDate != nil
            expandedDueDate = p.dueDate
            expandedPriority = p.priority ?? 0
            if let name = p.projectName {
                expandedProjectId = store.projects.first {
                    $0.title.lowercased().hasPrefix(name.lowercased())
                }?.id ?? store.inboxProject?.id
            } else {
                expandedProjectId = store.inboxProject?.id
            }
            expandedLabelIds = Set(p.labelTitles.compactMap { title in
                store.labels.first { $0.title.lowercased() == title.lowercased() }?.id
            })
            expandedRepeatAfter = p.repeatAfter
            expandedRepeatMode = p.repeatMode
        }
        isExpanded.toggle()
        onExpandToggle?(isExpanded)
    }

    // MARK: - Expanded section

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            expandedNotesBlock
            expandedChipsSection.padding(.top, 14)
            expandedSubtasksCard.padding(.top, 16)
        }
    }

    // MARK: - Notes block

    private var expandedNotesBlock: some View {
        TextField("Notes…", text: $expandedNotes, axis: .vertical)
            .font(.system(size: 14))
            .foregroundStyle(primaryText)
            .lineLimit(2...6)
            #if os(iOS)
            .autocorrectionDisabled()
            #endif
            .padding(15)
            .background(insetBg)
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Chips section

    private var expandedChipsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(hSpacing: 8, vSpacing: 8) {
                expandedProjectChip

                if expandedHasDueDate, let d = expandedDueDate {
                    chip(icon: "calendar", label: dateChipLabel(d), bg: dueBg, fg: dueFg) {
                        withAnimation { showExpandedDatePicker.toggle(); showExpandedReminderPicker = false }
                    }
                    .contextMenu {
                        Button("Clear due date", role: .destructive) {
                            expandedHasDueDate = false; expandedDueDate = nil
                            withAnimation { showExpandedDatePicker = false }
                        }
                    }
                }

                if expandedHasReminder {
                    chip(icon: "bell", label: reminderChipLabel(), bg: remBg, fg: remFg) {
                        withAnimation { showExpandedReminderPicker.toggle(); showExpandedDatePicker = false }
                    }
                    .contextMenu {
                        Button("Clear reminder", role: .destructive) {
                            expandedHasReminder = false
                            withAnimation { showExpandedReminderPicker = false }
                        }
                    }
                }

                if expandedRepeatAfter != nil || expandedRepeatMode == 1 {
                    chip(icon: "repeat", label: repeatChipLabel(), bg: repBg, fg: repFg) {
                        showingRepeatSheet = true
                    }
                    .contextMenu {
                        Button("Clear repeat", role: .destructive) {
                            expandedRepeatAfter = nil; expandedRepeatMode = nil
                        }
                    }
                }

                if expandedPriority > 0 {
                    Menu {
                        Button("None") { expandedPriority = 0 }
                        Divider()
                        ForEach(1...5, id: \.self) { p in
                            Button { expandedPriority = p } label: {
                                Label(priorityLabel(p), systemImage: expandedPriority == p ? "checkmark" : "")
                            }
                        }
                    } label: {
                        chipLabel(icon: "flag", label: priorityLabel(expandedPriority),
                                  bg: priorityChipBg(expandedPriority), fg: priorityChipFg(expandedPriority))
                    }
                    .buttonStyle(.plain)
                }

                ForEach(selectedExpandedLabels, id: \.id) { label in
                    let base = Color(vikunjaHex: label.hexColor)
                    let bg = base.map { cs == .dark ? $0.opacity(0.20) : $0.opacity(0.15) } ?? dueBg
                    let fg = base ?? dueFg
                    chip(icon: "tag", label: label.title, bg: bg, fg: fg) {
                        showLabelPicker = true
                    }
                }

                addChip
            }

            if showExpandedDatePicker {
                DatePicker(
                    "",
                    selection: Binding(
                        get: { expandedDueDate ?? Date() },
                        set: { expandedDueDate = $0; expandedHasDueDate = true }
                    ),
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .padding(.horizontal, 4)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if showExpandedReminderPicker {
                DatePicker("", selection: $expandedReminderDate,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .padding(.horizontal, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var expandedProjectChip: some View {
        let project = store.projects.first { $0.id == expandedProjectId }
        let base = Color(vikunjaHex: project?.hexColor) ?? Color(red: 107/255, green: 78/255, blue: 230/255)
        let bg = cs == .dark ? base.opacity(0.20) : base.opacity(0.12)
        let fg = cs == .dark ? base.opacity(0.90) : base

        return Menu {
            ForEach(store.projects) { proj in
                Button { expandedProjectId = proj.id } label: {
                    Label(proj.title, systemImage: expandedProjectId == proj.id ? "checkmark" : "folder")
                }
            }
        } label: {
            chipLabel(icon: "folder.fill", label: project?.title ?? "Inbox", bg: bg, fg: fg)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subtasks card

    private var expandedSubtasksCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Subtasks")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(primaryText)
                Spacer()
                if !subtaskTitles.isEmpty {
                    Text("\(subtaskTitles.count)")
                        .font(.system(size: 13))
                        .foregroundStyle(mutedText)
                }
            }
            .padding(.bottom, subtaskTitles.isEmpty ? 0 : 12)

            ForEach(subtaskTitles.indices, id: \.self) { idx in
                HStack(spacing: 11) {
                    Circle()
                        .stroke(circleStroke, lineWidth: 1.8)
                        .frame(width: 21, height: 21)
                    Text(subtaskTitles[idx])
                        .font(.system(size: 15))
                        .foregroundStyle(primaryText)
                        .lineLimit(2)
                    Spacer()
                    Button { subtaskTitles.remove(at: idx) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(mutedText)
                    }
                    .buttonStyle(.plain)
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
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.sentences)
                    #endif
                    .onSubmit {
                        let t = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { subtaskTitles.append(t); newSubtaskTitle = "" }
                    }
            }
            .padding(.top, subtaskTitles.isEmpty ? 0 : 6)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(insetBg)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    // MARK: - Footer

    private var footerRow: some View {
        HStack(spacing: 0) {
            Button("Cancel") { dismiss() }
                .font(.system(size: 16))
                .foregroundStyle(accentBlue)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])

            Spacer()

            Button {
                submit()
            } label: {
                Group {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add Task")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
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
            .disabled(parsed.cleanedTitle.isEmpty || isSubmitting)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    // MARK: - Chip helpers

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
            if !expandedHasDueDate {
                Button("Due Date") {
                    expandedHasDueDate = true
                    expandedDueDate = VikunjaAPI.applyDefaultTime(Date())
                    withAnimation { showExpandedDatePicker = true }
                }
            }
            if !expandedHasReminder {
                Button("Reminder") {
                    expandedHasReminder = true
                    expandedReminderDate = defaultReminderDate()
                    withAnimation { showExpandedReminderPicker = true; showExpandedDatePicker = false }
                }
            }
            if expandedRepeatAfter == nil && expandedRepeatMode != 1 {
                Button("Repeat") { showingRepeatSheet = true }
            }
            if expandedPriority == 0 {
                Button("Priority") { expandedPriority = 1 }
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

    // MARK: - Chip label helpers

    private func dateChipLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let day = cal.startOfDay(for: date)
        if day < today { return "Overdue" }
        if day == today { return "Today" }
        if day == cal.date(byAdding: .day, value: 1, to: today)! { return "Tomorrow" }
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }

    private func repeatChipLabel() -> String {
        if expandedRepeatMode == 1 { return "Monthly" }
        guard let ra = expandedRepeatAfter, ra > 0 else { return "Repeat" }
        let days = ra / 86_400
        switch days {
        case 1: return "Daily"; case 7: return "Weekly"; case 365: return "Yearly"
        default: return days % 7 == 0 ? "Every \(days / 7)w" : "Every \(days)d"
        }
    }

    private func reminderChipLabel() -> String {
        let fmt = DateFormatter(); fmt.dateStyle = .short; fmt.timeStyle = .short
        return fmt.string(from: expandedReminderDate)
    }

    private func defaultReminderDate() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        if let due = expandedDueDate {
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

    // MARK: - Selected labels

    private var selectedExpandedLabels: [VikunjaLabel] {
        store.labels
            .filter { expandedLabelIds.contains($0.id) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    // MARK: - Preview chips (collapsed)

    private var previewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let due = parsed.dueDate {
                    let currentYear = Calendar.current.component(.year, from: Date())
                    let dueYear = Calendar.current.component(.year, from: due)
                    let dueText = dueYear == currentYear
                        ? due.formatted(.dateTime.month(.abbreviated).day())
                        : due.formatted(.dateTime.month(.abbreviated).day().year())
                    previewChip(icon: "calendar", text: dueText)
                }
                if let priority = parsed.priority {
                    previewChip(icon: "flag.fill", text: "Priority \(priority)")
                }
                ForEach(parsed.labelTitles, id: \.self) { tag in
                    previewChip(icon: "tag.fill", text: tag)
                }
                if let project = parsed.projectName {
                    previewChip(icon: "circle.dashed", text: project)
                }
                if parsed.repeatAfter != nil {
                    previewChip(icon: "repeat", text: "Repeating")
                }
            }
        }
    }

    private func previewChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 12))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(accentBlue.opacity(0.12))
        .foregroundStyle(accentBlue)
        .clipShape(Capsule())
    }

    // MARK: - Label picker

    private var labelPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(store.labels.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) { label in
                    Button {
                        if expandedLabelIds.contains(label.id) {
                            expandedLabelIds.remove(label.id)
                        } else {
                            expandedLabelIds.insert(label.id)
                        }
                    } label: {
                        HStack {
                            let isSelected = expandedLabelIds.contains(label.id)
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

    // MARK: - Submission

    private func submit() {
        guard !isSubmitting else { return }
        let p = parsed
        guard !p.cleanedTitle.isEmpty else { return }

        isSubmitting = true
        errorMessage = nil

        Task {
            let targetProject: VikunjaProject?
            if isExpanded, let pid = expandedProjectId {
                targetProject = store.projects.first { $0.id == pid } ?? store.inboxProject
            } else if let name = p.projectName {
                targetProject = store.projects.first {
                    $0.title.lowercased().hasPrefix(name.lowercased())
                } ?? store.inboxProject
            } else {
                targetProject = store.inboxProject
            }

            guard let project = targetProject ?? store.projects.first else {
                errorMessage = "No project found to add task to."
                isSubmitting = false
                return
            }

            var resolvedLabels: [VikunjaLabel] = []
            if isExpanded {
                resolvedLabels = store.labels.filter { expandedLabelIds.contains($0.id) }
            } else {
                for title in p.labelTitles {
                    if let existing = store.labels.first(where: {
                        $0.title.lowercased() == title.lowercased()
                    }) {
                        resolvedLabels.append(existing)
                    } else if store.reachability.isOnline {
                        if let created = try? await VikunjaAPI.createLabel(title: title) {
                            resolvedLabels.append(created)
                            await MainActor.run { store.labels.append(created) }
                        }
                    }
                }
            }

            let effectiveDueDate = isExpanded ? (expandedHasDueDate ? expandedDueDate : nil) : p.dueDate
            let effectivePriority = isExpanded ? (expandedPriority > 0 ? expandedPriority : nil) : p.priority
            let notes: String? = isExpanded && !expandedNotes.isEmpty ? expandedNotes : nil
            let effectiveRepeatAfter = isExpanded ? expandedRepeatAfter : p.repeatAfter
            let effectiveRepeatMode = isExpanded ? expandedRepeatMode : p.repeatMode
            let effectiveReminders: [Date] =
                (isExpanded && expandedHasReminder) ? [expandedReminderDate] : []

            let pendingSubtasks = subtaskTitles.filter { !$0.isEmpty }

            if pendingSubtasks.isEmpty {
                store.createTask(
                    projectId: project.id,
                    title: p.cleanedTitle,
                    description: notes,
                    dueDate: effectiveDueDate,
                    priority: effectivePriority,
                    labels: resolvedLabels,
                    reminders: effectiveReminders,
                    repeatAfter: effectiveRepeatAfter,
                    repeatMode: effectiveRepeatMode
                )
            } else {
                guard store.reachability.isOnline else {
                    errorMessage = "Go online to add subtasks."
                    isSubmitting = false
                    return
                }
                do {
                    let created = try await VikunjaAPI.createTask(
                        projectId: project.id,
                        title: p.cleanedTitle,
                        description: notes,
                        dueDate: effectiveDueDate,
                        priority: effectivePriority,
                        labelIds: resolvedLabels.map(\.id),
                        reminders: effectiveReminders,
                        repeatAfter: effectiveRepeatAfter,
                        repeatMode: effectiveRepeatMode
                    )
                    for subTitle in pendingSubtasks {
                        let sub = try await VikunjaAPI.createTask(projectId: project.id, title: subTitle)
                        try await VikunjaAPI.addRelation(taskId: created.id, otherTaskId: sub.id, kind: "subtask")
                        VeyrnTelemetry.signal("SubtaskAdded")
                    }
                    VeyrnTelemetry.signal("TaskCreated")
                    await store.refresh()
                } catch {
                    errorMessage = VeyrnError.message(for: error)
                    isSubmitting = false
                    return
                }
            }

            dismiss()
            isSubmitting = false
        }
    }
}
