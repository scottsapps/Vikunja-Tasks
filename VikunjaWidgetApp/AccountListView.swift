import SwiftUI

/// Shown even with a single account — it's the only route to edit a bad
/// token or rename an account.
struct AccountListView: View {
    var store: TaskStore

    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [VeyrnAccount] = []
    @State private var editingAccount: VeyrnAccount?
    @State private var showAddAccount = false
    @State private var accountToDelete: VeyrnAccount?

    var body: some View {
        NavigationStack {
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
            }
            .navigationTitle("Accounts")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { reload() }
            .sheet(isPresented: $showAddAccount, onDismiss: reload) {
                AccountEditorView(mode: .create, store: store, onComplete: reload)
            }
            .sheet(item: $editingAccount, onDismiss: reload) { account in
                AccountEditorView(mode: .edit(account), store: store, onComplete: reload)
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
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
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
                await store.switchAccount(to: account.id)
                dismiss()
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
        if wasActive {
            Task { await store.handleAccountDeleted() }
        }
    }
}
