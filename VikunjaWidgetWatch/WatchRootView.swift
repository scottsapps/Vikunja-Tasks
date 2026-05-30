import SwiftUI

struct WatchRootView: View {
    @Bindable var store: WatchStore
    @State private var showingAdd = false

    var body: some View {
        TabView {
            ScheduledListView(store: store)
            InboxListView(store: store)
        }
        .tabViewStyle(.verticalPage)
        .task { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAdd) { AddTaskView(store: store) }
    }
}
