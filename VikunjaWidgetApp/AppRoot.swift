import SwiftUI

// MARK: - Offline indicator

private struct OfflinePill: View {
    let isOnline: Bool
    let pendingCount: Int

    var body: some View {
        let offline = !isOnline
        let hasPending = pendingCount > 0
        if offline || hasPending {
            HStack(spacing: 4) {
                Image(systemName: offline ? "wifi.slash" : "arrow.up.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(offline ? "Offline" : "\(pendingCount) pending")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(offline ? Color.secondary.opacity(0.18) : Color.orange.opacity(0.18))
            .foregroundStyle(offline ? Color.secondary : Color.orange)
            .clipShape(Capsule())
        }
    }
}

// MARK: - Sidebar selection

enum SidebarItem: Hashable {
    case inbox
    case today
    case logbook
    case project(Int)
}

// MARK: - Root view

struct AppRoot: View {
    var store: TaskStore
    @State private var selection: SidebarItem? = .today
    @State private var showSettings = false
    @State private var showQuickAdd = false
    @State private var showBulkImport = false
    @State private var searchText = ""
    @State private var showNewProject = false
    @State private var newProjectTitle = ""
    @State private var projectToDelete: VikunjaProject?

    // Drives iPhone NavigationStack
    @State private var navPath: [SidebarItem] = []

    @AppStorage("vikunja_font_size_offset") private var fontSizeOffset: Int = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if !VikunjaConfig.isConfigured {
                SettingsView(onSave: { Task { await store.refresh() } })
            } else if sizeClass == .compact {
                compactLayout   // iPhone: NavigationStack
            } else {
                regularLayout   // iPad / Mac: NavigationSplitView
            }
        }
        .environment(\.fontSizeOffset, fontSizeOffset)
        #if os(iOS)
        .onAppear {
            if let action = ShortcutRouter.shared.pendingAction {
                ShortcutRouter.shared.pendingAction = nil
                consumeShortcut(action)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vikunjaShortcutFired)) { _ in
            if let action = ShortcutRouter.shared.pendingAction {
                ShortcutRouter.shared.pendingAction = nil
                consumeShortcut(action)
            }
        }
        #endif
        .task {
            _ = await ReminderScheduler.requestPermission()
            guard VikunjaConfig.isConfigured else { return }
            await store.refresh()
            store.startPolling()
        }
        .onDisappear { store.stopPolling() }
        .onOpenURL { handleDeepLink($0) }
        .onChange(of: store.projects) { _, projects in
            if case .project(let id) = selection, !projects.contains(where: { $0.id == id }) {
                selection = .inbox
            }
            if let last = navPath.last, case .project(let id) = last,
               !projects.contains(where: { $0.id == id }) {
                navPath = Array(navPath.dropLast())
            }
        }
        .alert("Error", isPresented: Binding(
            get: { store.error != nil },
            set: { if !$0 { store.error = nil } }
        )) {
            Button("OK", role: .cancel) { store.error = nil }
        } message: {
            Text(store.error ?? "")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onSave: { Task { await store.refresh() } })
        }
        .sheet(isPresented: $showQuickAdd) {
            QuickAddSheet(store: store)
        }
        .sheet(isPresented: $showBulkImport) {
            BulkImportSheet(store: store)
        }
        .environment(store)
    }

    // MARK: - iPhone layout (NavigationStack)

    private var compactLayout: some View {
        NavigationStack(path: $navPath) {
            List {
                Section {
                    NavigationLink(value: SidebarItem.inbox) {
                        Label("Inbox", systemImage: "tray.fill")
                    }
                    .badge(store.inboxTasks().count)

                    NavigationLink(value: SidebarItem.today) {
                        Label("Scheduled", systemImage: "star.fill")
                    }
                    .badge(todayCount)

                    NavigationLink(value: SidebarItem.logbook) {
                        Label("Logbook", systemImage: "archivebox.fill")
                    }
                }

                Section {
                    ForEach(visibleProjects) { project in
                        NavigationLink(value: SidebarItem.project(project.id)) {
                            Label(project.title, systemImage: "folder.fill")
                        }
                        .badge(store.tasks(for: project).count)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                projectToDelete = project
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Projects")
                        Spacer()
                        Button { showNewProject = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Veyrn")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: SidebarItem.self) { item in
                Group {
                    if !searchText.isEmpty {
                        TaskListView(tasks: searchResults, mode: .byDate)
                            .navigationTitle("Search Results")
                    } else {
                        destinationView(for: item)
                    }
                }
                .searchable(text: $searchText, prompt: "Search tasks")
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showQuickAdd = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showBulkImport = true } label: {
                        Image(systemName: "arrow.down.doc")
                    }
                }
                ToolbarItem(placement: .navigation) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItem(placement: .status) {
                    OfflinePill(isOnline: store.reachability.isOnline, pendingCount: store.outbox.ops.count)
                }
            }
            .overlay {
                if store.isLoading && store.undoneTasks.isEmpty {
                    ProgressView()
                }
            }
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
                        Task { await store.deleteProject(id: project.id) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("All tasks in this project will be permanently deleted.")
            }
        }
    }

    // MARK: - iPad / Mac layout (NavigationSplitView)

    private var regularLayout: some View {
        NavigationSplitView {
            Sidebar(selection: $selection, store: store, onSettings: { showSettings = true })
        } detail: {
            Group {
                if !searchText.isEmpty {
                    TaskListView(tasks: searchResults, mode: .byDate)
                        .navigationTitle("Search Results")
                } else {
                    destinationView(for: selection)
                }
            }
            .searchable(text: $searchText, prompt: "Search tasks")
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gear")
                }
                .help("Settings")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showQuickAdd = true } label: {
                    Label("New Task", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Task (⌘N)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showBulkImport = true } label: {
                    Label("Bulk Import", systemImage: "arrow.down.doc")
                }
                .help("Bulk Import Tasks")
            }
            ToolbarItem(placement: .status) {
                OfflinePill(isOnline: store.reachability.isOnline, pendingCount: store.outbox.ops.count)
            }
        }
        #endif
    }

    // MARK: - Destination view (shared)

    @ViewBuilder
    private func destinationView(for item: SidebarItem?) -> some View {
        switch item {
        case .inbox:
            InboxView(store: store)
        case .today:
            TodayView(store: store)
        case .logbook:
            LogbookView(store: store)
        case .project(let id):
            if let project = store.projects.first(where: { $0.id == id }) {
                ProjectView(project: project, store: store)
            } else {
                ContentUnavailableView("Project not found", systemImage: "questionmark.circle")
            }
        case nil:
            ContentUnavailableView("Select a list", systemImage: "sidebar.left")
        }
    }

    // MARK: - Helpers

    private var visibleProjects: [VikunjaProject] {
        store.projects
            .filter { $0.title.lowercased() != "inbox" }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    private var todayCount: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return store.upcomingTasks().filter {
            guard let d = $0.effectiveDueDate else { return false }
            return cal.startOfDay(for: d) <= today
        }.count
    }

    private var searchResults: [VikunjaTask] {
        let q = searchText.lowercased()
        return store.undoneTasks.filter {
            $0.title.lowercased().contains(q) ||
            ($0.description ?? "").lowercased().contains(q) ||
            ($0.labels ?? []).contains { $0.title.lowercased().contains(q) }
        }
    }

    #if os(iOS)
    private func consumeShortcut(_ action: ShortcutRouter.ShortcutAction) {
        switch action {
        case .newTask:
            showQuickAdd = true
        case .today:
            if sizeClass == .compact { navPath = [.today] }
            else { selection = .today }
        }
    }
    #endif

    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "vikunja",
              url.host == "task",
              let idStr = url.pathComponents.dropFirst().first,
              let taskId = Int(idStr),
              let task = store.undoneTasks.first(where: { $0.id == taskId })
        else { return }

        let dest = SidebarItem.project(task.projectId)
        if sizeClass == .compact {
            navPath = [dest]
        } else {
            selection = dest
        }
    }
}
