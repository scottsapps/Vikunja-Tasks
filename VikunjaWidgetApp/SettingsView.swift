import SwiftUI
import WidgetKit

struct SettingsView: View {
    var store: TaskStore
    var onSave: (() -> Void)? = nil

    private enum ServerKind { case cloud, custom }

    @State private var accounts: [VeyrnAccount] = []
    @State private var showBugReport = false

    // Onboarding-only state — shown inline when there are no accounts yet,
    // matching the pre-multi-account first-run flow (no navigating two
    // levels deep just to type a token).
    @State private var name = ""
    @State private var serverKind: ServerKind = .custom
    @State private var host = ""
    @State private var token = ""
    @State private var errorMessage: String?

    #if os(iOS)
    // macOS's configured settings is a real `Settings` scene, not a sheet —
    // there's no "Done" button to dismiss (see `macBody`).
    @Environment(\.dismiss) private var dismiss
    #endif
    @AppStorage("vikunja_font_size_offset") private var fontSizeOffset: Int = 0
    @AppStorage(TaskSortPreferences.fieldKey) private var sortField: TaskSortField = .alphabetical
    @AppStorage(TaskSortPreferences.projectTieBreakKey) private var projectTieBreak: ProjectTieBreak = .alphabetical
    @AppStorage(TaskSortPreferences.undatedKey) private var undatedPlacement: UndatedPlacement = .bottom
    @AppStorage(TaskSortPreferences.projectOrderKey) private var projectOrder: ProjectOrder = .server
    @AppStorage("vikunja_telemetry_opt_in") private var telemetryOptIn: Bool = true

    #if os(iOS)
    // iPhone only: iPad and Mac keep the root list in a permanent sidebar, so
    // there is no opening page to pick (`LaunchPreferences.isSupported`).
    @AppStorage(LaunchPreferences.pageKey) private var launchPage: LaunchPage = .main
    @AppStorage(LaunchPreferences.projectKey) private var launchProjectKey: String = SidebarItem.inbox.storageKey
    #endif

    #if os(macOS)
    @State private var hotkeyKeyCode: UInt32 = VikunjaConfig.quickAddKeyCode
    @State private var hotkeyModifiers: UInt32 = VikunjaConfig.quickAddModifiers
    #endif

    private var isOnboarding: Bool { accounts.isEmpty }

    var body: some View {
        // Two genuinely different screens. Onboarding stays a single inline form —
        // there is no account yet, so a list of categories would be a menu of things
        // you cannot do, and the pre-multi-account flow deliberately never made you
        // navigate two levels deep just to type a token. Everything after that is
        // organised by platform: iOS/iPadOS keeps a grouped list (still a sheet,
        // still a "Done" button — that's how Settings looks there), while macOS uses
        // its own window with the tabbed layout every native Mac app's Settings uses
        // (see `macBody`).
        if isOnboarding {
            onboardingBody
        } else {
            configuredBody
        }
    }

    // MARK: - Onboarding (no accounts yet)

    private var onboardingBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Welcome to Veyrn")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Connect to your Vikunja instance.")
                            .foregroundStyle(.secondary)
                    }

                    onboardingForm

                    // Kept in both layouts, so someone who cannot sign in still has a
                    // way to report why.
                    helpSection
                }
            }

            HStack {
                Spacer()
                Button("Get Started") { getStarted() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSaveOnboarding)
            }
            .padding(.top, 16)
        }
        .padding(32)
        .onAppear { reload() }
        .sheet(isPresented: $showBugReport) { BugReportSheet() }
    }

    // MARK: - Configured settings

    private var configuredBody: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(iOS)
    // MARK: iOS/iPadOS: grouped list, organised into panes

    private var iosBody: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink {
                        AccountsPane(store: store, onChange: onSave)
                    } label: {
                        settingsRow("Accounts", systemImage: "person.crop.circle",
                                    detail: VikunjaConfig.activeAccount.map { Text(verbatim: $0.name) })
                    }
                }

                Section("Tasks") {
                    if LaunchPreferences.isSupported {
                        NavigationLink {
                            pane("Opening Page") { openingPageSection }
                        } label: {
                            settingsRow("Opening Page", systemImage: "arrow.forward.square",
                                        detail: Text(launchPage.title))
                        }
                    }

                    NavigationLink {
                        pane("Project & Task Order") { projectAndTaskOrderSection }
                    } label: {
                        settingsRow("Project & Task Order", systemImage: "arrow.up.arrow.down")
                    }

                    NavigationLink {
                        pane("Calendar") { CalendarSettingsView() }
                    } label: {
                        settingsRow("Calendar", systemImage: "calendar",
                                    detail: Text(CalendarSettingsSummary.current))
                    }
                }

                Section("Appearance") {
                    NavigationLink {
                        pane("Task Font Size") { fontSizeSection }
                    } label: {
                        settingsRow("Task Font Size", systemImage: "textformat.size",
                                    detail: Text(fontSizeLabel))
                    }
                }

                Section("Privacy") {
                    // One switch. A pane of its own would be more taps for less.
                    Toggle(isOn: $telemetryOptIn) {
                        Label("Share anonymous usage analytics", systemImage: "chart.bar")
                    }
                    .onChange(of: telemetryOptIn) { _, v in
                        UserDefaults.standard.set(v, forKey: "vikunja_telemetry_opt_in")
                    }
                }

                // A plain row, not a pane: this already is the report-a-bug
                // screen's one meaningful action, so tapping it goes straight
                // to the sheet instead of a "Help" landing page in between.
                Section {
                    Button {
                        showBugReport = true
                    } label: {
                        Label("Report a Bug", systemImage: "ladybug")
                    }
                } footer: {
                    Text("Sends a report to \(BugReportMail.supportAddress). You choose whether to attach the diagnostic log, and you can read it first.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // "Done", not "Cancel": every setting here applies immediately
                    // (@AppStorage, accounts save in their own editor), so there is
                    // nothing to cancel.
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { reload() }
        .sheet(isPresented: $showBugReport) {
            BugReportSheet()
        }
    }

    /// Every detail pane is the same shape: an existing section's content, scrollable,
    /// padded and titled. Reusing the section bodies unchanged is what keeps this
    /// reorganisation from also being a rewrite of every control in it.
    private func pane<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A root row: icon, name, and the current value on the trailing edge so the list
    /// answers "what is this set to?" without opening anything.
    ///
    /// `detail` is a `Text` rather than a `String` so each caller decides whether its
    /// value is translatable (`Text("Small")`) or user data that must not be
    /// (`Text(verbatim: accountName)`).
    private func settingsRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        detail: Text? = nil
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 8)
            detail?
                .foregroundStyle(.secondary)
        }
        // The whole row is the target, not just the words in it.
        .contentShape(Rectangle())
    }

    // MARK: - Opening page (iOS)

    private var openingPageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // All four choices visible and tappable at once — a `.menu` picker
            // hid them behind a second tap, which was the whole complaint.
            VStack(spacing: 0) {
                ForEach(LaunchPage.allCases) { page in
                    Button {
                        launchPage = page
                    } label: {
                        HStack {
                            Text(page.title)
                            Spacer()
                            if launchPage == page {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    if page != LaunchPage.allCases.last {
                        Divider()
                    }
                }
            }

            if launchPage == .project {
                // A flat menu, deliberately — a disclosure chevron is
                // meaningless in a `.menu` Picker, and every project must stay
                // selectable (this is how someone picks their opening page).
                // Nested projects are just indented by leading spaces so the
                // hierarchy stays legible; the tree is walked fully expanded so
                // none is hidden. Unlike the four fixed pages above, a project
                // list can run long, so it keeps the menu style.
                Picker("Project", selection: $launchProjectKey) {
                    Text("Inbox").tag(SidebarItem.inbox.storageKey)
                    ForEach(store.projectTree(expanded: Set(store.visibleProjects(order: projectOrder).map(\.id)), order: projectOrder)) { row in
                        Text(String(repeating: "   ", count: min(row.depth, 3)) + row.project.title)
                            .tag(SidebarItem.project(row.project.id).storageKey)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Text("Where Veyrn goes when you open it, every time. Main is the list of Inbox, Scheduled, Logbook and your projects; Last Used leaves you where you were.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    #endif

    #if os(macOS)
    // MARK: macOS: a tabbed window, like every other Mac app's Settings

    private var macBody: some View {
        TabView {
            // Analytics lives here too (3.5) — macOS has no separate Privacy
            // tab, one switch doesn't earn a whole one, and Accounts is the
            // closest thing this window has to a "General" tab.
            AccountsPane(store: store, onChange: onSave)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }

            // Task Order + Appearance share a tab; Calendar does not (3.5) —
            // its calendar chooser can run to a dozen rows once access is
            // granted, and that used to visually push Task Order out of the
            // same tab. `.formStyle(.grouped)` is what actually gives this
            // the boxed-section look every native Mac Settings window has —
            // a bare `Form` renders almost flush with the window edge.
            Form {
                Section("Project Order") {
                    projectOrderSection
                }
                Section("Task Order") {
                    taskOrderSection
                }
                Section("Task Font Size") {
                    fontSizeSection
                }
                Section("Quick Add Shortcut") {
                    quickAddSection
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Tasks", systemImage: "checklist") }

            Form {
                CalendarSettingsView()
            }
            .formStyle(.grouped)
            .tabItem { Label("Calendar", systemImage: "calendar") }

            // The tab *is* the report-a-bug screen — no launcher button in
            // between, since clicking the tab is already the one step.
            BugReportBody()
                .padding(24)
                .tabItem { Label("Help", systemImage: "ladybug") }
        }
        // No padding on the `TabView` itself — that would also pad the tab
        // bar inward, away from the window edge, which no native Mac
        // Settings window does. `.formStyle(.grouped)` gives the Form tabs
        // their own inset; the Help tab gets an explicit one instead, since
        // `BugReportBody` is a plain `VStack`, not a `Form`.
        .frame(width: 520, height: 480)
        .onAppear { reload() }
    }
    #endif

    // MARK: - Appearance

    private var fontSizeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Font Size", selection: $fontSizeOffset) {
                Text("Small").tag(-1)
                Text("Medium").tag(0)
                Text("Large").tag(2)
                Text("Extra Large").tag(4)
            }
            .pickerStyle(.segmented)

            Text("Applies to task titles in every list.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var fontSizeLabel: LocalizedStringKey {
        switch fontSizeOffset {
        case ..<0:  return "Small"
        case 0:     return "Medium"
        case 1...2: return "Large"
        default:    return "Extra Large"
        }
    }

    #if os(macOS)
    private var quickAddSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HotkeyRecorderView(keyCode: $hotkeyKeyCode, modifiers: $hotkeyModifiers)
                .onChange(of: hotkeyKeyCode) { _, _ in saveHotkey() }
                .onChange(of: hotkeyModifiers) { _, _ in saveHotkey() }
            Text("Click to record a new global shortcut (default: ⌃Space)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    #endif

    // MARK: - Help

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showBugReport = true
            } label: {
                Label("Report a Bug", systemImage: "ladybug")
            }
            .buttonStyle(.bordered)

            // Interpolated, not written out: a fork that changes
            // `BugReportMail.supportAddress` would otherwise still show this
            // project's address to its own users.
            Text("Sends a report to \(BugReportMail.supportAddress). You choose whether to attach the diagnostic log, and you can read it first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Project & task order

    #if os(iOS)
    private var projectAndTaskOrderSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Project Order").font(.headline)
                projectOrderSection
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Task Order").font(.headline)
                taskOrderSection
            }
        }
    }
    #endif

    private var projectOrderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Order projects by", selection: $projectOrder) {
                ForEach(ProjectOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.segmented)

            Text("Server Order matches the order shown on the Vikunja web app and other Vikunja clients. Alphabetical always sorts projects by title.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var taskOrderSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Sort tasks by", selection: $sortField) {
                ForEach(TaskSortField.allCases) { field in
                    Text(field.title).tag(field)
                }
            }
            .pickerStyle(.segmented)

            if sortField == .project {
                Picker("Within each project", selection: $projectTieBreak) {
                    ForEach(ProjectTieBreak.allCases) { tieBreak in
                        Text(tieBreak.title).tag(tieBreak)
                    }
                }
                .pickerStyle(.segmented)
                Text("Projects run in alphabetical order; this orders the tasks inside each one.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Text("Tasks with no date")
                Spacer()
                Picker("Tasks with no date", selection: $undatedPlacement) {
                    ForEach(UndatedPlacement.allCases) { placement in
                        Text(placement.title).tag(placement)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            Text(orderExplanation)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var orderExplanation: String {
        let within: String
        switch sortField {
        case .alphabetical: within = "by title"
        case .priority:     within = "highest priority first, then by title"
        case .project:      within = "by project, then "
            + (projectTieBreak == .priority ? "by priority" : "by title")
        }
        let undated = undatedPlacement == .top ? "above" : "below"
        return "Scheduled and project lists stay grouped by day, with each day ordered \(within). "
            + "Tasks with no due date sit \(undated) the dated ones. The Inbox uses the same order without the day grouping."
    }

    // MARK: - Onboarding form (no accounts yet)

    private var onboardingForm: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("Name")
                    .font(.headline)
                TextField("e.g. Home", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, newValue in
                        if newValue.count > VikunjaConfig.maxAccountNameLength {
                            name = String(newValue.prefix(VikunjaConfig.maxAccountNameLength))
                        }
                    }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Server")
                    .font(.headline)
                Picker("Server", selection: $serverKind) {
                    Text("Custom server").tag(ServerKind.custom)
                    Text("Vikunja Cloud").tag(ServerKind.cloud)
                }
                .pickerStyle(.segmented)
                .onChange(of: serverKind) { _, kind in
                    if kind == .cloud { host = VikunjaConfig.vikunjaCloudHost }
                }

                if serverKind == .custom {
                    TextField("https://tasks.example.com", text: $host)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    Text("Your Vikunja server — without /api/v1")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Token")
                    .font(.headline)
                SecureField("tk_…", text: $token)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    #endif
                Text("Vikunja → Profile → Settings → API Tokens")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Recommended: set a long expiration (1 year or more) and grant all permissions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    private var canSaveOnboarding: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func getStarted() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        let account = VeyrnAccount(id: UUID(), name: trimmedName, host: trimmedHost)
        errorMessage = nil
        do {
            try VikunjaConfig.addAccount(account, token: trimmedToken)
        } catch VikunjaConfig.AccountError.duplicateName {
            errorMessage = "An account is already named \"\(trimmedName)\"."
            return
        } catch {
            return
        }

        VeyrnTelemetry.signal("SignedIn", parameters: [
            "serverKind": serverKind == .cloud ? "cloud" : "custom",
        ])

        WidgetCenter.shared.reloadAllTimelines()
        Task {
            await store.switchAccount(to: account.id)
            reload()
            onSave?()
        }
    }

    private func reload() {
        accounts = VikunjaConfig.accounts
        #if os(iOS)
        // A chosen project can disappear underneath the setting — deleted, or
        // the choice was made on another account. Without this the menu picker
        // renders blank on a tag it can't find.
        if case .project(let id) = SidebarItem(storageKey: launchProjectKey),
           !store.projects.isEmpty,
           !store.projects.contains(where: { $0.id == id }) {
            launchProjectKey = SidebarItem.inbox.storageKey
        }
        #endif
    }

    #if os(macOS)
    private func saveHotkey() {
        VikunjaConfig.quickAddKeyCode = hotkeyKeyCode
        VikunjaConfig.quickAddModifiers = hotkeyModifiers
        NotificationCenter.default.post(name: .vikunjaHotkeyChanged, object: nil)
    }
    #endif
}
