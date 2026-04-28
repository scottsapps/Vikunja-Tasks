import SwiftUI

struct LogbookView: View {
    var store: TaskStore
    @State private var hasLoaded = false

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
            guard !hasLoaded else { return }
            hasLoaded = true
            await store.refreshLogbook()
        }
        .refreshable {
            await store.refreshLogbook()
        }
        .overlay {
            if store.doneTasks.isEmpty && !hasLoaded {
                ProgressView()
            }
        }
    }
}
