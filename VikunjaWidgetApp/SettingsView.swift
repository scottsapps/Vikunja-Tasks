import SwiftUI
import WidgetKit

struct SettingsView: View {
    var store: TaskStore
    var onSave: (() -> Void)? = nil

    private enum ServerKind { case cloud, custom }

    @State private var accounts: [VeyrnAccount] = []
    @State private var showAccountList = false
    @State private var showAddAccount = false
    @State private var showBugReport = false

    // Onboarding-only state — shown inline when there are no accounts yet,
    // matching the pre-multi-account first-run flow (no navigating two
    // levels deep just to type a token).
    @State private var name = ""
    @State private var serverKind: ServerKind = .custom
    @State private var host = ""
    @State private var token = ""
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("vikunja_font_size_offset") private var fontSizeOffset: Int = 0
    @AppStorage(TaskSortPreferences.fieldKey) private var sortField: TaskSortField = .alphabetical
    @AppStorage(TaskSortPreferences.projectTieBreakKey) private var projectTieBreak: ProjectTieBreak = .alphabetical
    @AppStorage(TaskSortPreferences.undatedKey) private var undatedPlacement: UndatedPlacement = .bottom
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
        // organised into panes, because the flat scroll had grown past what fits on a
        // phone and the calendar chooser alone can run to a dozen rows.
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

    // MARK: - Configured settings (organised into panes)

    private var configuredBody: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink {
                        pane("Accounts") { accountsSection }
                    } label: {
                        settingsRow("Accounts", systemImage: "person.crop.circle",
                                    detail: VikunjaConfig.activeAccount.map { Text(verbatim: $0.name) })
                    }
                }

                Section("Tasks") {
                    #if os(iOS)
                    if LaunchPreferences.isSupported {
                        NavigationLink {
                            pane("Opening Page") { openingPageSection }
                        } label: {
                            settingsRow("Opening Page", systemImage: "arrow.forward.square",
                                        detail: Text(launchPage.title))
                        }
                    }
                    #endif

                    NavigationLink {
                        pane("Task Order") { taskOrderSection }
                    } label: {
                        settingsRow("Task Order", systemImage: "arrow.up.arrow.down",
                                    detail: Text(sortField.title))
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

                    #if os(macOS)
                    NavigationLink {
                        pane("Quick Add Shortcut") { quickAddSection }
                    } label: {
                        settingsRow("Quick Add Shortcut", systemImage: "keyboard")
                    }
                    #endif
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

                Section("Help") {
                    NavigationLink {
                        pane("Help") { helpSection }
                    } label: {
                        settingsRow("Report a Bug", systemImage: "ladybug")
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    // "Done", not "Cancel": every setting here applies immediately
                    // (@AppStorage, the hotkey saves on change, accounts save in their
                    // own editor), so there is nothing to cancel. On macOS it is also
                    // the only way out — there is no swipe-to-dismiss.
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        #if os(macOS)
        // A sheet with a NavigationStack has no intrinsic size to speak of; without
        // this it opens too small to show a pane's contents.
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        #endif
        .onAppear { reload() }
        .sheet(isPresented: $showAccountList, onDismiss: reload) {
            AccountListView(store: store)
        }
        .sheet(isPresented: $showAddAccount, onDismiss: { reload(); onSave?() }) {
            AccountEditorView(mode: .create, store: store, onComplete: { reload(); onSave?() })
        }
        .sheet(isPresented: $showBugReport) {
            BugReportSheet()
        }
    }

    // MARK: - Pane scaffolding

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
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
            #if os(macOS)
            // iOS draws a disclosure chevron for a `NavigationLink` in a `List`;
            // macOS draws nothing, so without this the rows read as static text and
            // there is no hint they open anything. Matches System Settings.
            Image(systemName: "chevron.forward")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            #endif
        }
        // The whole row is the target, not just the words in it.
        .contentShape(Rectangle())
    }

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

    // MARK: - Opening page (iOS)

    #if os(iOS)
    private var openingPageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Opening Page", selection: $launchPage) {
                ForEach(LaunchPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if launchPage == .project {
                // A flat menu, deliberately — a disclosure chevron is
                // meaningless in a `.menu` Picker, and every project must stay
                // selectable (this is how someone picks their opening page).
                // Nested projects are just indented by leading spaces so the
                // hierarchy stays legible; the tree is walked fully expanded so
                // none is hidden.
                Picker("Project", selection: $launchProjectKey) {
                    Text("Inbox").tag(SidebarItem.inbox.storageKey)
                    ForEach(store.projectTree(expanded: Set(store.visibleProjects.map(\.id)))) { row in
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

    // MARK: - Task order

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

    // MARK: - Accounts section (already configured)

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showAccountList = true
            } label: {
                HStack {
                    Text("Active Account")
                    Spacer()
                    Text(VikunjaConfig.activeAccount?.name ?? "")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                showAddAccount = true
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .disabled(accounts.count >= VikunjaConfig.maxAccounts)

            if accounts.count >= VikunjaConfig.maxAccounts {
                Text("Maximum of 5 accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
