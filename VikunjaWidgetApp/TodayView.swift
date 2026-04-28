import SwiftUI

struct TodayView: View {
    var store: TaskStore
    @State private var isRefreshing = false

    var body: some View {
        TaskListView(
            tasks: store.upcomingTasks(),
            mode: .byDate
        )
        .navigationTitle("Today")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                refreshButton
            }
        }
        .refreshable {
            await store.refresh()
        }
        .overlay {
            if store.isLoading && store.upcomingTasks().isEmpty {
                ProgressView()
            }
        }
    }

    private var refreshButton: some View {
        Button {
            Task {
                isRefreshing = true
                await store.refresh()
                isRefreshing = false
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(isRefreshing || store.isLoading)
    }
}
