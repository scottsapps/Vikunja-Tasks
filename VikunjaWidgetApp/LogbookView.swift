import SwiftUI

struct LogbookView: View {
    var store: TaskStore

    var body: some View {
        TaskListView(
            tasks: store.doneTasks,
            mode: .byCompletionDate
        )
        .navigationTitle("Logbook")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await store.refreshLogbook()
        }
        .refreshable {
            await store.refreshLogbook()
        }
    }
}
