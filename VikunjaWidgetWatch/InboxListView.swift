import SwiftUI

struct InboxListView: View {
    @Bindable var store: WatchStore
    @State private var showingAdd = false

    var body: some View {
        List {
            ForEach(store.inboxTasks(), id: \.id) { task in
                WatchTaskRow(store: store, task: task)
            }
        }
        .navigationTitle("Inbox")
        .refreshable { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) { AddTaskView(store: store) }
        .overlay {
            if store.isLoading && store.tasks.isEmpty {
                ProgressView()
            }
        }
    }
}
