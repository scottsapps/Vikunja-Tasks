import SwiftUI

struct ProjectView: View {
    let project: VikunjaProject
    var store: TaskStore

    @State private var activeTagFilter: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Tag filter chips (horizontal scroll row)
            if !availableLabels.isEmpty {
                tagFilterRow
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                Divider()
            }

            TaskListView(
                tasks: projectTasks,
                mode: .byDate,
                activeTagFilter: activeTagFilter
            )
        }
        .navigationTitle(project.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            if let color = Color(vikunjaHex: project.hexColor) {
                ToolbarItem(placement: .principal) {
                    Label(project.title, systemImage: "folder.fill")
                        .foregroundStyle(color)
                        .font(.headline)
                        .labelStyle(.titleAndIcon)
                }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoading)
            }
        }
        .refreshable {
            await store.refresh()
        }
        // Reset tag filter when project changes
        .onChange(of: project.id) {
            activeTagFilter = []
        }
    }

    // MARK: - Tag filter chips

    private var tagFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableLabels) { label in
                    LabelChip(
                        label: label,
                        isSelected: activeTagFilter.contains(label.title),
                        onTap: { toggleTag(label.title) }
                    )
                }
                if !activeTagFilter.isEmpty {
                    Button("Clear") {
                        activeTagFilter = []
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Computed

    private var projectTasks: [VikunjaTask] {
        store.tasks(for: project)
    }

    /// All unique labels present in this project's undone tasks
    private var availableLabels: [VikunjaLabel] {
        var seen: [Int: VikunjaLabel] = [:]
        for task in projectTasks {
            for label in task.labels ?? [] {
                seen[label.id] = label
            }
        }
        return seen.values.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    private func toggleTag(_ tag: String) {
        if activeTagFilter.contains(tag) {
            activeTagFilter.remove(tag)
        } else {
            activeTagFilter.insert(tag)
        }
    }
}

// MARK: - Label chip (color-aware)

private struct LabelChip: View {
    let label: VikunjaLabel
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            let labelColor = Color(vikunjaHex: label.hexColor)
            let bg: Color = isSelected
                ? (labelColor ?? Color.accentColor)
                : (labelColor?.opacity(0.15) ?? Color.secondary.opacity(0.12))
            let fg: Color = isSelected
                ? (labelColor != nil ? (labelColor!.contrastingForeground) : .white)
                : (labelColor ?? .primary)

            Text(label.title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(bg)
                .foregroundStyle(fg)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
