import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct BulkImportSheet: View {
    var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var spec: BulkImportSpec?
    @State private var parseError: String?
    @State private var phase: Phase = .idle
    @State private var isDragTargeted = false

    // fileImporter is only used on iOS; macOS uses NSOpenPanel directly.
    @State private var showFilePicker = false

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
                dropZone
            }

            Spacer(minLength: 0)
            bottomBar
        }
        .padding(24)
        // Fill the sheet window fully so the entire area is a valid drop target,
        // including the Spacer region (which has no renderable surface on its own).
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity,
               alignment: .topLeading)
        .contentShape(Rectangle())  // makes empty space hit-testable for drops
        .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
        #if os(iOS)
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.plainText, .text],
            onCompletion: { result in
                switch result {
                case .success(let url): loadFile(from: url)
                case .failure(let err): parseError = err.localizedDescription
                }
            }
        )
        #endif
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack {
            Text("Bulk Import Tasks")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
            Button {
                pickFile()
            } label: {
                Label(spec == nil ? "Choose File" : "Choose Different File",
                      systemImage: "doc.badge.plus")
                    .font(.callout)
            }
            .buttonStyle(.bordered)
            .disabled(phase == .importing)
        }
    }

    /// Instruction area that doubles as a visible drop-zone highlight target.
    private var dropZone: some View {
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

            HStack {
                Spacer()
                Label("or drag & drop a file anywhere in this window", systemImage: "arrow.up.to.line")
                    .font(.caption)
                    .foregroundStyle(isDragTargeted ? Color.accentColor : .secondary)
                Spacer()
            }
            .padding(.top, 4)
        }
        .padding(isDragTargeted ? 12 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDragTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isDragTargeted)
    }

    @ViewBuilder
    private func previewContent(_ spec: BulkImportSpec) -> some View {
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

    // MARK: - File picking

    private func pickFile() {
#if os(macOS)
        // NSOpenPanel must be created and presented on the main thread.
        // Task { @MainActor in } guarantees that even if the call site escapes
        // the View's implicit actor context. beginSheetModal attaches the panel
        // to the existing sheet window rather than floating it separately.
        Task { @MainActor in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.plainText, .text]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.message = "Choose a task import file"
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { response in
                    guard response == .OK, let url = panel.url else { return }
                    loadFile(from: url)
                }
            } else {
                panel.begin { response in
                    guard response == .OK, let url = panel.url else { return }
                    loadFile(from: url)
                }
            }
        }
#else
        showFilePicker = true
#endif
    }

    // MARK: - Drag & drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // File dragged from Finder: provider carries a file URL.
        // loadDataRepresentation is more reliable than loadObject(ofClass: URL.self)
        // for cross-process Finder drags.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { loadFile(from: url) }
            }
            return true
        }

        // Plain text dragged directly (e.g. from a text editor selection).
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { parseText(text) }
            }
            return true
        }

        return false
    }

    // MARK: - Loading & parsing

    private func loadFile(from url: URL) {
        spec = nil
        parseError = nil
        phase = .idle

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            parseText(text)
        } catch {
            parseError = "Could not read file: \(error.localizedDescription)"
        }
    }

    private func parseText(_ text: String) {
        switch BulkImportParser.parse(text) {
        case .success(let s):
            spec = s
            parseError = nil
        case .failure(let err):
            spec = nil
            parseError = err.localizedDescription
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
        DiagnosticLog.breadcrumb("bulkImport")
        DiagnosticLog.info("bulk import: \(spec.tasks.count) tasks, \(spec.labelTitles.count) labels")
        defer { DiagnosticLog.endBreadcrumb("bulkImport") }

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
