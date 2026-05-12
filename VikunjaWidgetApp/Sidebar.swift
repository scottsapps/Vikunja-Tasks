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
                ForEach(visibleProjects) { project in
                    Label(project.title, systemImage: "folder.fill")
                        .badge(projectCount(project))
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
            Text("All tasks in this project will be permanently deleted.")
        }
    }

    // MARK: - Helpers

    private var visibleProjects: [VikunjaProject] {
        store.projects
            .filter { $0.title.lowercased() != "inbox" }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

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

    private func projectCount(_ project: VikunjaProject) -> Int {
        store.tasks(for: project).count
    }
}
