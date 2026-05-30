import SwiftUI

struct InboxListView: View {
    @Bindable var store: WatchStore

    var body: some View {
        List {
            ForEach(store.inboxTasks(), id: \.id) { task in
                WatchTaskRow(store: store, task: task)
            }
        }
        .navigationTitle("Inbox")
        .refreshable { await store.refresh() }
        .overlay {
            if store.isLoading && store.tasks.isEmpty {
                ProgressView()
            }
        }
    }
}
