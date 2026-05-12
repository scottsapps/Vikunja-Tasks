import SwiftUI

struct QuickAddSheet: View {
    var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    private var parsed: QuickAddResult {
        QuickAddParser.parse(inputText, knownProjects: store.projects, knownLabels: store.labels)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title
            Text("New Task")
                .font(.title3)
                .fontWeight(.semibold)

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

            // Live preview chips
            if !inputText.isEmpty {
                previewRow
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
    }

    // MARK: - Preview chips

    private var previewRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let due = parsed.dueDate {
                    previewChip(icon: "calendar", text: due.formatted(.dateTime.month(.abbreviated).day()))
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
            if let name = p.projectName {
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

            // Resolve labels from cache; attempt to create unknown ones online (skip if offline).
            var resolvedLabels: [VikunjaLabel] = []
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
                // Unknown labels that can't be created offline are silently skipped.
            }

            // Enqueue via store (handles outbox + optimistic merge).
            store.createTask(
                projectId: project.id,
                title: p.cleanedTitle,
                dueDate: p.dueDate,
                priority: p.priority,
                labels: resolvedLabels,
                repeatAfter: p.repeatAfter,
                repeatMode: p.repeatMode
            )

            dismiss()
            isSubmitting = false
        }
    }
}
