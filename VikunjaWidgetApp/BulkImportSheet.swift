import SwiftUI
import UniformTypeIdentifiers

struct BulkImportSheet: View {
    var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var spec: BulkImportSpec?
    @State private var parseError: String?
    @State private var showFilePicker = false
    @State private var phase: Phase = .idle

    enum Phase: Equatable {
        case idle
        case importing
        case done(count: Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            headerRow

            if let err = parseError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            }

            if let spec {
                previewContent(spec)
            } else if parseError == nil {
                instructionsView
            }

            Spacer(minLength: 0)
            bottomBar
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 480)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.plainText, .text],
            onCompletion: handleFile
        )
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack {
            Text("Bulk Import Tasks")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
            Button {
                showFilePicker = true
            } label: {
                Label(spec == nil ? "Choose File" : "Choose Different File",
                      systemImage: "doc.badge.plus")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .disabled(phase == .importing)
        }
    }

    private var instructionsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Expected file format:")
                .font(.subheadline)
                .fontWeight(.medium)
            Text("""
                Work
                urgent, feature
                2024-04-01 Fix the login bug
                2024-04-03 Write release notes
                """)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("Line 1: project name  ·  Line 2: comma-separated labels (leave blank if none)  ·  Remaining lines: yyyy-mm-dd followed by task title")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func previewContent(_ spec: BulkImportSpec) -> some View {
        // Project + labels summary
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Project") {
                HStack(spacing: 4) {
                    Text(spec.projectName)
                    if resolvedProject(for: spec) == nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }

            if !spec.labelTitles.isEmpty {
                LabeledContent("Labels") {
                    Text(spec.labelTitles.joined(separator: ", "))
                }
            }

            LabeledContent("Tasks") {
                Text("\(spec.tasks.count)")
            }
        }
        .font(.subheadline)

        Divider()

        // Task list preview
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(spec.tasks) { task in
                    HStack(spacing: 10) {
                        Text(task.dueDate.formatted(.dateTime.month(.abbreviated).day().year()))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Text(task.title)
                            .font(.subheadline)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: 260)

        if !spec.skippedLines.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("\(spec.skippedLines.count) line(s) could not be parsed and will be skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if case .done(let count) = phase {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(count) task(s) queued for creation.")
                    .font(.callout)
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            if case .done = phase {
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            } else {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])
            }

            Spacer()

            if let spec, phase == .idle {
                Button {
                    Task { await importTasks(spec) }
                } label: {
                    Label("Import \(spec.tasks.count) Task\(spec.tasks.count == 1 ? "" : "s")",
                          systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(resolvedProject(for: spec) == nil)
                .help(resolvedProject(for: spec) == nil
                      ? "Project '\(spec.projectName)' not found in your Vikunja account."
                      : "")
            }

            if phase == .importing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    // MARK: - File handling

    private func handleFile(_ result: Result<URL, Error>) {
        spec = nil
        parseError = nil
        phase = .idle

        switch result {
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                switch BulkImportParser.parse(text) {
                case .success(let s): spec = s
                case .failure(let err): parseError = err.localizedDescription
                }
            } catch {
                parseError = "Could not read file: \(error.localizedDescription)"
            }
        case .failure(let error):
            parseError = error.localizedDescription
        }
    }

    // MARK: - Import

    private func resolvedProject(for spec: BulkImportSpec) -> VikunjaProject? {
        store.projects.first { $0.title.lowercased() == spec.projectName.lowercased() }
            ?? store.projects.first { $0.title.lowercased().hasPrefix(spec.projectName.lowercased()) }
    }

    private func importTasks(_ spec: BulkImportSpec) async {
        guard let project = resolvedProject(for: spec) else { return }
        phase = .importing

        // Resolve labels — create unknown ones online; skip if offline.
        var resolvedLabels: [VikunjaLabel] = []
        for title in spec.labelTitles {
            if let existing = store.labels.first(where: { $0.title.lowercased() == title.lowercased() }) {
                resolvedLabels.append(existing)
            } else if store.reachability.isOnline {
                if let created = try? await VikunjaAPI.createLabel(title: title) {
                    resolvedLabels.append(created)
                    await MainActor.run { store.labels.append(created) }
                }
            }
        }

        // Enqueue all tasks. createTask is synchronous (outbox); the outbox drains asynchronously.
        for task in spec.tasks {
            store.createTask(
                projectId: project.id,
                title: task.title,
                dueDate: task.dueDate,
                labels: resolvedLabels
            )
        }

        phase = .done(count: spec.tasks.count)
    }
}

