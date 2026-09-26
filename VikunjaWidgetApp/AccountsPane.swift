import SwiftUI

/// The list of configured accounts — active one checked, tap another to
/// switch, edit/delete per row, and an Add button — shown directly, not
/// behind a summary row. Used as the "Accounts" destination in Settings on
/// every platform: an iOS/iPadOS `NavigationLink` push, or the macOS Settings
/// window's "Accounts" tab. It is the only route to rename an account or fix
/// a bad token.
struct AccountsPane: View {
    var store: TaskStore
    var onChange: (() -> Void)? = nil

    @State private var accounts: [VeyrnAccount] = []
    @State private var editingAccount: VeyrnAccount?
    @State private var showAddAccount = false
    @State private var accountToDelete: VeyrnAccount?

    #if os(macOS)
    // macOS has no separate Privacy tab (3.5) — one switch doesn't earn a
    // whole tab, and this is the closest thing to "General" it has.
    @AppStorage("vikunja_telemetry_opt_in") private var telemetryOptIn: Bool = true
    #endif

    var body: some View {
        List {
            Section {
                ForEach(accounts) { account in
                    row(for: account)
                }
            }

            Section {
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

            #if os(macOS)
            Section {
                Toggle(isOn: $telemetryOptIn) {
                    Label("Share anonymous usage analytics", systemImage: "chart.bar")
                }
                .onChange(of: telemetryOptIn) { _, v in
                    UserDefaults.standard.set(v, forKey: "vikunja_telemetry_opt_in")
                    VeyrnTelemetry.setOptIn(v)
                }
            }
            #endif
        }
        #if os(iOS)
        // On macOS this is a Settings tab, whose label already says
        // "Accounts" — a `navigationTitle` there would just rename the whole
        // Settings window as you switch tabs.
        .navigationTitle("Accounts")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { reload() }
        .sheet(isPresented: $showAddAccount, onDismiss: { reload(); onChange?() }) {
            AccountEditorView(mode: .create, store: store, onComplete: { reload(); onChange?() })
        }
        .sheet(item: $editingAccount, onDismiss: { reload(); onChange?() }) { account in
            AccountEditorView(mode: .edit(account), store: store, onComplete: { reload(); onChange?() })
        }
        .confirmationDialog(
            "Delete \"\(accountToDelete?.name ?? "")\"?",
            isPresented: Binding(get: { accountToDelete != nil }, set: { if !$0 { accountToDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let account = accountToDelete {
                Button("Delete", role: .destructive) { delete(account) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func row(for account: VeyrnAccount) -> some View {
        let isActive = account.id == VikunjaConfig.activeAccountId
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                Text(account.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
            #if os(iOS)
            Button {
                editingAccount = account
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            #else
            // macOS has no swipe actions, and a context menu is undiscoverable
            // — these need to be visible controls or the Mac app has no way to
            // fix a bad token or remove an account.
            Button {
                editingAccount = account
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit \(account.name)")

            Button {
                accountToDelete = account
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete \(account.name)")
            #endif
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isActive else { return }
            Task {
                await store.switchAccount(to: account.id, reason: .userSwitch)
                reload()
                onChange?()
            }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                accountToDelete = account
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        #else
        .contextMenu {
            Button("Edit") { editingAccount = account }
            Button("Delete", role: .destructive) { accountToDelete = account }
        }
        #endif
    }

    private func reload() {
        accounts = VikunjaConfig.accounts
    }

    private func delete(_ account: VeyrnAccount) {
        let wasActive = account.id == VikunjaConfig.activeAccountId
        VikunjaConfig.deleteAccount(id: account.id)
        reload()
        onChange?()
        if wasActive {
            Task { await store.handleAccountDeleted() }
        }
    }
}
