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
    @AppStorage("vikunja_telemetry_opt_in") private var telemetryOptIn: Bool = true

    #if os(macOS)
    @State private var hotkeyKeyCode: UInt32 = VikunjaConfig.quickAddKeyCode
    @State private var hotkeyModifiers: UInt32 = VikunjaConfig.quickAddModifiers
    #endif

    private var isOnboarding: Bool { accounts.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The Help section pushed this screen past what fits on a small
            // iPhone in a large Dynamic Type setting — the body is scrollable
            // now, with the footer button kept outside so Done/Get Started
            // stays pinned regardless of content height.
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(isOnboarding ? "Welcome to Veyrn" : "Settings")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Connect to your Vikunja instance.")
                            .foregroundStyle(.secondary)
                    }

                    if isOnboarding {
                        onboardingForm
                    } else {
                        accountsSection
                    }

                    // Font size
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Task Font Size")
                            .font(.headline)
                        Picker("Font Size", selection: $fontSizeOffset) {
                            Text("Small").tag(-1)
                            Text("Medium").tag(0)
                            Text("Large").tag(2)
                            Text("Extra Large").tag(4)
                        }
                        .pickerStyle(.segmented)
                    }

                    // Analytics opt-in
                    Toggle("Share anonymous usage analytics", isOn: $telemetryOptIn)
                        .onChange(of: telemetryOptIn) { _, v in
                            UserDefaults.standard.set(v, forKey: "vikunja_telemetry_opt_in")
                        }

                    #if os(macOS)
                    // Quick Add Shortcut
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quick Add Shortcut")
                            .font(.headline)
                        HotkeyRecorderView(keyCode: $hotkeyKeyCode, modifiers: $hotkeyModifiers)
                            .onChange(of: hotkeyKeyCode) { _, _ in saveHotkey() }
                            .onChange(of: hotkeyModifiers) { _, _ in saveHotkey() }
                        Text("Click to record a new global shortcut (default: ⌃Space)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    #endif

                    // Help — shown in both onboarding and configured layouts,
                    // so a user who can't sign in still has a way to report it.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Help")
                            .font(.headline)
                        Button {
                            showBugReport = true
                        } label: {
                            Label("Report a Bug", systemImage: "ladybug")
                        }
                        .buttonStyle(.bordered)
                        Text("Sends a report to scottsapps@protonmail.com. You choose whether to attach the diagnostic log, and you can read it first.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                if isOnboarding {
                    Button("Get Started") { getStarted() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSaveOnboarding)
                } else {
                    // "Done", not "Cancel": every setting on this screen
                    // applies immediately (font size and analytics are
                    // @AppStorage, the hotkey saves on change, accounts save
                    // in their own editor), so there is nothing to cancel.
                    // On macOS this is also the only way out — there's no
                    // swipe-to-dismiss.
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 16)
        }
        .padding(32)
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

    // MARK: - Accounts section (already configured)

    private var accountsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts")
                .font(.headline)

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
    }

    #if os(macOS)
    private func saveHotkey() {
        VikunjaConfig.quickAddKeyCode = hotkeyKeyCode
        VikunjaConfig.quickAddModifiers = hotkeyModifiers
        NotificationCenter.default.post(name: .vikunjaHotkeyChanged, object: nil)
    }
    #endif
}
