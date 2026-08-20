import SwiftUI

struct TodayView: View {
    var store: TaskStore

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
        .quickAddToolbarItem(store: store)
        .taskListRefreshToolbar(store: store)
        .refreshable {
            await store.refresh()
        }
        .overlay {
            if store.isLoading && store.upcomingTasks().isEmpty {
                ProgressView()
            }
        }
    }
}
