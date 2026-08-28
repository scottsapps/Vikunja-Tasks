import SwiftUI

/// One row in the Pending Changes sheet. Built by `TaskStore`, which is the
/// only thing that can resolve a `TaskRef` to a human-readable title.
struct PendingChange: Identifiable {
    let id: UUID            // the PendingOp's id — the discard handle
    let icon: String        // SF Symbol
    let kindLabel: String   // "New task", "Edit", "Completed", …
    let taskTitle: String
    let queuedAt: Date
    /// True for a queued `.create`: discarding deletes the task outright,
    /// because it exists nowhere but this queue. Drives the harsher confirm.
    let deletesTask: Bool
}

/// Reached by tapping the toolbar "N pending" pill. Lists what is queued,
/// explains why it is stuck (`store.lastDrainFailureMessage`, shown verbatim),
/// and offers Try Again plus per-row and bulk discard.
struct PendingChangesSheet: View {
    var store: TaskStore
    @Environment(\.dismiss) private var dismiss

    @State private var changeToDiscard: PendingChange?
    @State private var showDiscardAll = false

    var body: some View {
        NavigationStack {
            Group {
                if store.pendingChanges.isEmpty {
                    // The queue drained while the sheet was open. Don't
                    // auto-dismiss — yanking the sheet away mid-read is the
                    // disorientation this feature exists to fix.
                    ContentUnavailableView {
                        Label("All changes synced", systemImage: "checkmark.circle")
                    } description: {
                        Text("Everything on this device has reached your server.")
                    }
                } else {
                    changeList
                }
            }
            .navigationTitle("Pending Changes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                changeToDiscard?.deletesTask == true ? "Delete this task?" : "Discard this change?",
                isPresented: Binding(
                    get: { changeToDiscard != nil },
                    set: { if !$0 { changeToDiscard = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let change = changeToDiscard {
                    if change.deletesTask {
                        Button("Delete Task", role: .destructive) {
                            Task { await store.discard(opId: change.id) }
                        }
                    } else {
                        Button("Discard Change", role: .destructive) {
                            Task { await store.discard(opId: change.id) }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if let change = changeToDiscard {
                    if change.deletesTask {
                        Text("\"\(change.taskTitle)\" was never uploaded to your server, so discarding it deletes it permanently.")
                    } else {
                        Text("The task will go back to the version on your server. Your change will be lost.")
                    }
                }
            }
            .confirmationDialog(
                "Discard all pending changes?",
                isPresented: $showDiscardAll,
                titleVisibility: .visible
            ) {
                Button("Discard All", role: .destructive) {
                    Task { await store.discardAll() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                discardAllMessage
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    // MARK: - List

    private var changeList: some View {
        List {
            if let message = store.lastDrainFailureMessage {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                ForEach(store.pendingChanges) { change in
                    row(for: change)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { footerButtons }
    }

    private func row(for change: PendingChange) -> some View {
        HStack(spacing: 12) {
            Image(systemName: change.icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.kindLabel)
                    .font(.headline)
                Text(change.taskTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(change.queuedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            // No swipeActions — macOS has none, and a context menu alone is
            // undiscoverable (AccountListView precedent). Visible button on both.
            Button("Discard") { changeToDiscard = change }
                .buttonStyle(.borderless)
                .disabled(store.isDraining)
        }
        .padding(.vertical, 2)
    }

    private var footerButtons: some View {
        HStack {
            Button {
                Task { await store.drainOutbox() }
            } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .disabled(store.isDraining)

            Spacer()

            Button(role: .destructive) {
                showDiscardAll = true
            } label: {
                Label("Discard All", systemImage: "trash")
            }
            .disabled(store.isDraining)
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Copy

    /// "This will delete 3 new tasks and undo 17 changes. This cannot be undone."
    /// — with a zero half dropped entirely.
    ///
    /// Built as three whole-sentence `Text` literals rather than by joining
    /// String fragments: a literal reaches the string catalog and can be
    /// translated, while an interpolated `String` cannot and would ship this
    /// dialog as permanent English. `^[…](inflect: true)` is what pluralizes
    /// "task"/"tasks" — hand-rolled `== 1 ? "" : "s"` only ever works for
    /// English, and most of Veyrn's users aren't in an English-speaking market.
    @ViewBuilder
    private var discardAllMessage: some View {
        let summary = store.pendingDiscardSummary
        if summary.creates > 0 && summary.others > 0 {
            Text("This will delete ^[\(summary.creates) new task](inflect: true) and undo ^[\(summary.others) change](inflect: true). This cannot be undone.")
        } else if summary.creates > 0 {
            Text("This will delete ^[\(summary.creates) new task](inflect: true). This cannot be undone.")
        } else {
            Text("This will undo ^[\(summary.others) change](inflect: true). This cannot be undone.")
        }
    }
}
