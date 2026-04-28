import SwiftUI

struct ProjectView: View {
    let project: VikunjaProject
    var store: TaskStore

    @State private var activeTagFilter: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            // Tag filter chips (horizontal scroll row)
            if !availableTags.isEmpty {
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
                ForEach(availableTags, id: \.self) { tag in
                    TagChip(
                        title: tag,
                        isSelected: activeTagFilter.contains(tag),
                        onTap: { toggleTag(tag) }
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

    /// All unique tags present in this project's undone tasks
    private var availableTags: [String] {
        var seen = Set<String>()
        for task in projectTasks {
            for label in task.labels ?? [] {
                seen.insert(label.title)
            }
        }
        return seen.sorted()
    }

    private func toggleTag(_ tag: String) {
        if activeTagFilter.contains(tag) {
            activeTagFilter.remove(tag)
        } else {
            activeTagFilter.insert(tag)
        }
    }
}

// MARK: - Tag chip

private struct TagChip: View {
    let title: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}
