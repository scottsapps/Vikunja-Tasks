import SwiftUI

// MARK: - Offline indicator

private struct OfflinePill: View {
    let isOnline: Bool
    let pendingCount: Int
    /// The network says we're online but the last refresh timed out — show it
    /// here rather than as an alert; the cached list is still valid.
    var isReconnecting: Bool = false
    /// A refresh is in flight and what's on screen predates it enough to be
    /// worth labelling, rather than silently swapping under the user.
    var isUpdating: Bool = false

    private enum State {
        case offline, reconnecting, pending, updating
    }

    var body: some View {
        // Pending outranks updating: a queued write the user should know
        // about beats a routine fetch.
        let state: State? = {
            if !isOnline { return .offline }
            if isReconnecting { return .reconnecting }
            if pendingCount > 0 { return .pending }
            if isUpdating { return .updating }
            return nil
        }()

        if let state {
            HStack(spacing: 4) {
                Image(systemName: icon(state))
                    .font(.system(size: 11, weight: .semibold))
                Text(title(state))
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint(state).opacity(0.18))
            .foregroundStyle(tint(state))
            .clipShape(Capsule())
        }
    }

    private func icon(_ state: State) -> String {
        switch state {
        case .offline: return "wifi.slash"
        case .reconnecting: return "arrow.triangle.2.circlepath"
        case .pending: return "arrow.up.circle"
        case .updating: return "arrow.clockwise"
        }
    }

    private func title(_ state: State) -> String {
        switch state {
        case .offline: return "Offline"
        case .reconnecting: return "Reconnecting…"
        case .pending: return "\(pendingCount) pending"
        case .updating: return "Updating…"
        }
    }

    private func tint(_ state: State) -> Color {
        switch state {
        case .offline, .reconnecting, .updating: return .secondary
        case .pending: return .orange
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
                SettingsView(store: store, onSave: { Task { await store.refresh(reason: "settings") } })
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
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .veyrnNudgeReceived)) { _ in
            // Nobody asked for this refresh, so nothing about it should ever
            // raise a dialog — 502/503/504 route into the pill instead.
            Task { await store.refresh(background: true, reason: "nudge") }
        }
        #endif
        .task {
            _ = await ReminderScheduler.requestPermission()
            guard VikunjaConfig.isConfigured else { return }
            #if os(iOS)
            // A BGTask wake launches the whole app into the background, where
            // this refresh duplicates the one BackgroundRefresh is already
            // doing — and then gets frozen mid-flight when iOS re-suspends us,
            // "completing" half an hour later against stale state. Let the
            // background task own that path; the foreground refresh happens on
            // the scenePhase → active transition.
            if UIApplication.shared.applicationState == .background {
                DiagnosticLog.info("launch context: background — launch refresh skipped")
                return
            }
            DiagnosticLog.info("launch context: foreground")
            #endif
            await store.refreshWithRetry()
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
            SettingsView(store: store, onSave: { Task { await store.refresh(reason: "settings") } })
        }
        .sheet(isPresented: $showQuickAdd) {
            QuickAddSheet(store: store, defaultProjectId: currentProjectId)
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
                            HStack(spacing: 11) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(Color(vikunjaHex: project.hexColor) ?? Color.accentColor)
                                    .imageScale(.large)
                                    .frame(width: 26)
                                Text(project.title)
                            }
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
                        TaskListView(tasks: searchResults(for: item), mode: item == .logbook ? .byCompletionDate : .byDate)
                            .navigationTitle("Search Results")
                    } else {
                        destinationView(for: item)
                    }
                }
                .searchable(text: $searchText, prompt: "Search tasks")
                .task(id: searchText) {
                    if item == .logbook { store.updateLogbookSearch(searchText) }
                }
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
                    OfflinePill(isOnline: store.reachability.isOnline, pendingCount: store.outbox.ops.count, isReconnecting: store.transientRefreshFailure, isUpdating: store.isShowingStaleData)
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
                    TaskListView(tasks: searchResults(for: selection), mode: selection == .logbook ? .byCompletionDate : .byDate)
                        .navigationTitle("Search Results")
                } else {
                    destinationView(for: selection)
                }
            }
            .searchable(text: $searchText, prompt: "Search tasks")
            // Keyed on selection too (unlike the iPhone destination, which is
            // pushed fresh per item) — the split-view detail is one long-lived
            // Group, so switching sidebar items alone wouldn't otherwise
            // re-evaluate this against the new selection.
            .task(id: "\(String(describing: selection))|\(searchText)") {
                if selection == .logbook { store.updateLogbookSearch(searchText) }
            }
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
                OfflinePill(isOnline: store.reachability.isOnline, pendingCount: store.outbox.ops.count, isReconnecting: store.transientRefreshFailure, isUpdating: store.isShowingStaleData)
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

    /// The project currently on screen, if the user is inside one — a task
    /// started from the toolbar (or ⌘N) then begins in that project instead of
    /// the Inbox. The Mac's global quick-add panel is deliberately not part of
    /// this: it fires from other apps, where there is no view to inherit from.
    private var currentProjectId: Int? {
        let item: SidebarItem? = sizeClass == .compact ? navPath.last : selection
        if case .project(let id) = item { return id }
        return nil
    }

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

    private func searchResults(for item: SidebarItem?) -> [VikunjaTask] {
        // On v2 servers, a Logbook search is answered server-side against the
        // entire completion history (see `TaskStore.updateLogbookSearch`) —
        // prefer that over filtering only what's already paged in locally.
        if item == .logbook, let serverResults = store.logbookSearchResults {
            return serverResults
        }
        let q = searchText.lowercased()
        let pool = item == .logbook ? store.doneTasks : store.undoneTasks
        return pool.filter {
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
