import SwiftUI

struct Sidebar: View {
    @Binding var selection: SidebarItem?
    var store: TaskStore
    var onSettings: (() -> Void)? = nil

    @State private var showNewProject = false
    @State private var newProjectTitle = ""
    @State private var projectToDelete: VikunjaProject?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Inbox", systemImage: "tray.fill")
                    .badge(inboxCount)
                    .tag(SidebarItem.inbox)

                Label("Scheduled", systemImage: "star.fill")
                    .tint(.yellow)
                    .badge(todayCount)
                    .tag(SidebarItem.today)

                Label("Logbook", systemImage: "archivebox.fill")
                    .tag(SidebarItem.logbook)
            }

            Section {
                ForEach(store.projectTree(expanded: store.projectExpansion.expanded)) { row in
                    let project = row.project
                    let projectColor = Color(vikunjaHex: project.hexColor) ?? Color.accentColor
                    HStack(spacing: 11) {
                        expandChevron(for: row)
                        Image(systemName: "folder.fill")
                            .foregroundStyle(projectColor)
                            .imageScale(.large)
                            .frame(width: 26)
                        Text(project.title)
                    }
                    .padding(.leading, CGFloat(min(row.depth, 3)) * 16)
                    .badge(badgeCount(for: row))
                    .tag(SidebarItem.project(project.id))
                    .contextMenu {
                        Button(role: .destructive) {
                            projectToDelete = project
                        } label: {
                            Label("Delete Project…", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button { showNewProject = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Veyrn")
        #if os(iOS)
        .toolbar {
            if let onSettings {
                ToolbarItem(placement: .navigation) {
                    Button { onSettings() } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        }
        #endif
        .alert("New Project", isPresented: $showNewProject) {
            TextField("Project name", text: $newProjectTitle)
            Button("Create") {
                let title = newProjectTitle.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { Task { await store.createProject(title: title) } }
                newProjectTitle = ""
            }
            Button("Cancel", role: .cancel) { newProjectTitle = "" }
        }
        .confirmationDialog(
            "Delete \"\(projectToDelete?.title ?? "")\"?",
            isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let project = projectToDelete {
                Button("Delete Project and All Tasks", role: .destructive) {
                    if selection == .project(project.id) { selection = .inbox }
                    Task { await store.deleteProject(id: project.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            deleteProjectMessage(for: projectToDelete)
        }
    }

    /// The delete-confirmation body. Vikunja deletes a project's sub-projects
    /// along with it, so when there are any, the copy says so and names the
    /// count rather than understating what will happen.
    @ViewBuilder
    private func deleteProjectMessage(for project: VikunjaProject?) -> some View {
        let subCount = project.map { store.descendantProjectCount(for: $0) } ?? 0
        if subCount > 0 {
            Text("This will also delete ^[\(subCount) sub-project](inflect: true) and all of their tasks. This can't be undone.")
        } else {
            Text("All tasks in this project will be permanently deleted.")
        }
    }

    // MARK: - Nested project rows

    /// The expand/collapse control, shown only when the project actually has
    /// children. A leaf gets an equally-sized clear spacer instead so every
    /// folder icon in a sibling group stays vertically aligned. The chevron is
    /// a real `Button` with a rectangular hit area — a bare glyph is far too
    /// small a target — and it turns rather than pops between states.
    @ViewBuilder
    private func expandChevron(for row: TaskStore.ProjectTreeRow) -> some View {
        if row.hasChildren {
            Button {
                store.projectExpansion.toggle(row.project.id)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(row.expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.2), value: row.expanded)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.expanded ? Text("Collapse \(row.project.title)") : Text("Expand \(row.project.title)"))
        } else {
            Color.clear.frame(width: 16, height: 16)
        }
    }

    /// A collapsed parent rolls its descendants' counts up into its badge so
    /// collapsing never hides work; expanded, it shows only its own, with the
    /// children showing theirs — nothing on screen double-counts.
    private func badgeCount(for row: TaskStore.ProjectTreeRow) -> Int {
        if row.hasChildren && !row.expanded {
            return store.rolledUpTaskCount(for: row.project)
        }
        return store.tasks(for: row.project).count
    }

    // MARK: - Helpers

    private var inboxCount: Int {
        store.inboxTasks().count
    }

    private var todayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return store.upcomingTasks().filter {
            guard let d = $0.effectiveDueDate else { return false }
            return cal.startOfDay(for: d) <= today
        }.count
    }
}
