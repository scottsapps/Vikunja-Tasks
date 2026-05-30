import SwiftUI

struct ScheduledListView: View {
    @Bindable var store: WatchStore

    var body: some View {
        List {
            ForEach(store.scheduledGroups()) { group in
                Section(group.title) {
                    ForEach(group.tasks, id: \.id) { task in
                        WatchTaskRow(store: store, task: task)
                    }
                }
            }
        }
        .navigationTitle("Scheduled")
        .refreshable { await store.refresh() }
        .overlay {
            if store.isLoading && store.tasks.isEmpty {
                ProgressView()
            }
        }
        .overlay {
            if let msg = store.errorMessage {
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(6)
            }
        }
    }
}
