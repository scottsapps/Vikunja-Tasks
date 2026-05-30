import SwiftUI

struct WatchRootView: View {
    @Bindable var store: WatchStore

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    ScheduledListView(store: store)
                } label: {
                    Label("Scheduled", systemImage: "calendar")
                }
                NavigationLink {
                    InboxListView(store: store)
                } label: {
                    Label("Inbox", systemImage: "tray")
                }
            }
            .navigationTitle("Veyrn")
        }
        .task { await store.refresh() }
    }
}
