import SwiftUI

struct WatchRootView: View {
    @Bindable var store: WatchStore
    @State private var openScheduled = false

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
            .navigationDestination(isPresented: $openScheduled) {
                ScheduledListView(store: store)
            }
        }
        .onOpenURL { url in
            if url.host == "scheduled" { openScheduled = true }
        }
        .task {
            store.loadFromCache()
            await store.refresh()
        }
    }
}
