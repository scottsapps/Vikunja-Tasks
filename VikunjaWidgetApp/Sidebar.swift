import SwiftUI

struct Sidebar: View {
    @Binding var selection: SidebarItem?
    var store: TaskStore

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Inbox", systemImage: "tray.fill")
                    .badge(inboxCount)
                    .tag(SidebarItem.inbox)

                Label("Today", systemImage: "star.fill")
                    .tint(.yellow)
                    .badge(todayCount)
                    .tag(SidebarItem.today)

                Label("Logbook", systemImage: "archivebox.fill")
                    .tag(SidebarItem.logbook)
            }

            if !visibleProjects.isEmpty {
                Section("Projects") {
                    ForEach(visibleProjects) { project in
                        Label(project.title, systemImage: "circle.dashed")
                            .badge(projectCount(project))
                            .tag(SidebarItem.project(project.id))
                    }
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationTitle("Vikunja")
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
