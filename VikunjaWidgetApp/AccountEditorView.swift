import SwiftUI

/// Create or edit a single account. Saving in create mode adds the account
/// and immediately switches to it; saving in edit mode on the active account
/// re-syncs the mirror and refreshes (or, if the host changed, runs the full
/// switch path — a different host is a different dataset).
struct AccountEditorView: View {
    enum Mode {
        case create
        case edit(VeyrnAccount)
    }

    var mode: Mode
    var store: TaskStore
    var onComplete: () -> Void

    private enum ServerKind { case cloud, custom }

    @State private var name = ""
    @State private var serverKind: ServerKind = .custom
    @State private var host = ""
    @State private var token = ""
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false

    @Environment(\.dismiss) private var dismiss

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editingAccount: VeyrnAccount? {
        if case .edit(let account) = mode { return account }
        return nil
    }

    var body: some View {
        NavigationStack {
            fields
            .navigationTitle(isEditMode ? "Edit Account" : "Add Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear { loadInitial() }
            .confirmationDialog(
                "Delete \"\(editingAccount?.name ?? "")\"?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { deleteAccount() }
                Button("Cancel", role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    // MARK: - Fields

    /// Deliberately **not** a `Form`. On macOS a `Form` promotes each field's
    /// placeholder string into a leading label column, which stranded the
    /// example URL and "tk_…" out in the margin and pushed the fields off the
    /// sheet. Outside a Form the title renders as a normal placeholder, so one
    /// layout works on both platforms — same structure `SettingsView` uses.
    private var fields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account Name")
                        .font(.headline)
                    TextField("Personal", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > VikunjaConfig.maxAccountNameLength {
                                name = String(newValue.prefix(VikunjaConfig.maxAccountNameLength))
                            }
                        }
                    Text("\(name.count)/\(VikunjaConfig.maxAccountNameLength) characters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Server")
                        .font(.headline)
                    Picker("Server", selection: $serverKind) {
                        Text("Custom server").tag(ServerKind.custom)
                        Text("Vikunja Cloud").tag(ServerKind.cloud)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
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
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Recommended: set a long expiration (1 year or more) and grant all permissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if isEditMode {
                    Divider()
                    Button("Delete Account", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadInitial() {
        guard let account = editingAccount else { return }
        name = account.name
        host = account.host
        token = VikunjaConfig.token(for: account.id)
        serverKind = account.host == VikunjaConfig.vikunjaCloudHost ? .cloud : .custom
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil

        if let original = editingAccount {
            let updated = VeyrnAccount(id: original.id, name: trimmedName, host: trimmedHost)
            do {
                try VikunjaConfig.updateAccount(updated, token: trimmedToken)
            } catch VikunjaConfig.AccountError.duplicateName {
                errorMessage = "An account is already named \"\(trimmedName)\"."
                return
            } catch {
                return
            }

            let isActive = VikunjaConfig.activeAccountId == original.id
            let hostChanged = original.host != trimmedHost
            Task {
                if isActive {
                    if hostChanged {
                        await store.switchAccount(to: original.id)
                    } else {
                        await store.refresh()
                    }
                }
                onComplete()
            }
            dismiss()
        } else {
            let account = VeyrnAccount(id: UUID(), name: trimmedName, host: trimmedHost)
            do {
                try VikunjaConfig.addAccount(account, token: trimmedToken)
            } catch VikunjaConfig.AccountError.limitReached {
                errorMessage = "Maximum of 5 accounts."
                return
            } catch VikunjaConfig.AccountError.duplicateName {
                errorMessage = "An account is already named \"\(trimmedName)\"."
                return
            } catch {
                return
            }

            VeyrnTelemetry.signal("SignedIn", parameters: [
                "serverKind": serverKind == .cloud ? "cloud" : "custom",
            ])

            Task {
                await store.switchAccount(to: account.id)
                onComplete()
            }
            dismiss()
        }
    }

    private func deleteAccount() {
        guard let account = editingAccount else { return }
        let wasActive = VikunjaConfig.activeAccountId == account.id
        VikunjaConfig.deleteAccount(id: account.id)
        Task {
            if wasActive {
                await store.handleAccountDeleted()
            }
            onComplete()
        }
        dismiss()
    }
}
