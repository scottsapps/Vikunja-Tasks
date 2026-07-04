import SwiftUI

struct ScheduledListView: View {
    @Bindable var store: WatchStore
    @State private var showingAdd = false

    var body: some View {
        List {
            Button {
                Task { await store.refresh() }
            } label: {
                Label(store.isLoading ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoading)

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
