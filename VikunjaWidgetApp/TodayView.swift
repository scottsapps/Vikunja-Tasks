import SwiftUI

struct TodayView: View {
    var store: TaskStore
    @State private var isRefreshing = false
    #if os(iOS)
    @State private var showQuickAdd = false
    #endif

    var body: some View {
        TaskListView(
            tasks: store.upcomingTasks(),
            mode: .byDate,
            suppressUpcomingDueDate: true
        )
        .navigationTitle("Scheduled")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button { showQuickAdd = true } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                refreshButton
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showQuickAdd) {
            QuickAddSheet(store: store)
        }
        #endif
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
