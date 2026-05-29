import SwiftUI

struct QuickAddSheet: View {
    var store: TaskStore
    var onExpandToggle: ((Bool) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    // Expanded section state
    @State private var isExpanded = false
    @State private var expandedHasDueDate = false
    @State private var expandedDueDate: Date? = nil
    @State private var expandedPriority: Int = 0
    @State private var expandedProjectId: Int? = nil
    @State private var expandedLabelIds: Set<Int> = []
    @State private var expandedNotes = ""

    private var parsed: QuickAddResult {
        QuickAddParser.parse(inputText, knownProjects: store.projects, knownLabels: store.labels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title row
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
                        .foregroundStyle(isExpanded ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "More options")
            }

            // Input field
            TextField("Buy milk *groceries +Home !2 tomorrow", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 15))
                .focused($fieldFocused)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.sentences)
                #endif
                .onSubmit { submit() }

            // Live preview chips (collapsed only, or always when parsing produces results)
            if !inputText.isEmpty && !isExpanded {
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

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add Task")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsed.cleanedTitle.isEmpty || isSubmitting)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24)
        .onAppear { fieldFocused = true }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
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
        }
        isExpanded.toggle()
        onExpandToggle?(isExpanded)
    }

    // MARK: - Expanded section

    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            // Metadata row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    expandedDueDateButton
                    Divider().frame(height: 24)
                    expandedProjectMenu
                    Divider().frame(height: 24)
                    expandedLabelsMenu
                    Divider().frame(height: 24)
                    expandedPriorityMenu
                }
            }
            .frame(height: 36)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Notes
            TextField("Notes (optional)", text: $expandedNotes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .lineLimit(3...5)
                #if os(iOS)
                .autocorrectionDisabled()
                #endif
        }
    }

    // MARK: - Expanded due date

    private var expandedDueDateButton: some View {
        Group {
            if expandedHasDueDate {
                HStack(spacing: 0) {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: { expandedDueDate ?? Date() },
                            set: { expandedDueDate = $0; expandedHasDueDate = true }
                        ),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .padding(.horizontal, 8)

                    Button {
                        expandedHasDueDate = false
                        expandedDueDate = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            } else {
                Button {
                    expandedHasDueDate = true
                    expandedDueDate = VikunjaAPI.applyDefaultTime(Date())
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 12))
                        Text("Due date")
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 10)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Expanded project menu

    private var expandedProjectMenu: some View {
        Menu {
            ForEach(store.projects) { project in
                Button {
                    expandedProjectId = project.id
                } label: {
                    Label(
                        project.title,
                        systemImage: expandedProjectId == project.id ? "checkmark" : "folder"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                if let pid = expandedProjectId,
                   let name = store.projects.first(where: { $0.id == pid })?.title {
                    Text(name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                } else {
                    Text("Project")
                        .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 10)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded labels menu

    private var expandedLabelsMenu: some View {
        Menu {
            ForEach(store.labels.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }) { label in
                Button {
                    if expandedLabelIds.contains(label.id) {
                        expandedLabelIds.remove(label.id)
                    } else {
                        expandedLabelIds.insert(label.id)
                    }
                } label: {
                    Label(label.title, systemImage: expandedLabelIds.contains(label.id) ? "checkmark" : "")
                }
            }
            if store.labels.isEmpty {
                Text("No labels yet").foregroundStyle(.secondary)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expandedLabelIds.isEmpty ? "tag" : "tag.fill")
                    .font(.system(size: 12))
                if !expandedLabelIds.isEmpty {
                    let names = store.labels
                        .filter { expandedLabelIds.contains($0.id) }
                        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
                        .map(\.title)
                        .joined(separator: ", ")
                    Text(names)
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .foregroundStyle(expandedLabelIds.isEmpty ? .secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded priority menu

    private var expandedPriorityMenu: some View {
        Menu {
            Button("None") { expandedPriority = 0 }
            Divider()
            ForEach(1...5, id: \.self) { p in
                Button {
                    expandedPriority = p
                } label: {
                    Label(priorityLabel(p), systemImage: expandedPriority == p ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: expandedPriority > 0 ? "flag.fill" : "flag")
                    .font(.system(size: 12))
                    .foregroundStyle(expandedPriority > 0 ? priorityColor(expandedPriority) : .secondary)
                if expandedPriority > 0 {
                    Text(priorityLabel(expandedPriority))
                        .font(.system(size: 12))
                        .foregroundStyle(priorityColor(expandedPriority))
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

    // MARK: - Preview chips

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
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.12))
        .foregroundStyle(Color.accentColor)
        .clipShape(Capsule())
    }

    // MARK: - Submission

    private func submit() {
        let p = parsed
        guard !p.cleanedTitle.isEmpty else { return }

        isSubmitting = true
        errorMessage = nil

        Task {
            // Resolve project
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

            // Resolve labels
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

            store.createTask(
                projectId: project.id,
                title: p.cleanedTitle,
                description: notes,
                dueDate: effectiveDueDate,
                priority: effectivePriority,
                labels: resolvedLabels,
                repeatAfter: p.repeatAfter,
                repeatMode: p.repeatMode
            )

            dismiss()
            isSubmitting = false
        }
    }

    // MARK: - Priority helpers

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
        case 1: return .secondary
        case 2: return .blue
        case 3: return .orange
        case 4, 5: return .red
        default: return .secondary
        }
    }
}
