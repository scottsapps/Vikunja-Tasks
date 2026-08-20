import SwiftUI

struct InboxView: View {
    var store: TaskStore

    var body: some View {
        TaskListView(
            tasks: store.inboxTasks(),
            mode: .noGrouping
        )
        .navigationTitle("Inbox")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .quickAddToolbarItem(store: store)
        .taskListRefreshToolbar(store: store)
        .refreshable {
            await store.refresh()
        }
        .overlay {
            if store.isLoading && store.inboxTasks().isEmpty {
                ProgressView()
            }
        }
    }
}
