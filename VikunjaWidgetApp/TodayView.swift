import SwiftUI
#if os(macOS)
import WidgetKit
#endif

struct TodayView: View {
    var store: TaskStore
    @State private var isRefreshing = false
    #if os(iOS)
    @State private var showQuickAdd = false
    #endif
    #if os(macOS)
    @State private var isRefreshingWidget = false
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
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                widgetRefreshButton
            }
            #endif
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

    #if os(macOS)
    // Separate from `refreshButton`: that one just re-fetches into the app,
    // which alone doesn't move the Mac widget along — it's cache-first and
    // only redraws on its own ~15-minute timer or right after an edit made
    // in this app, so a change from elsewhere (the web UI, another device)
    // can sit stale on the widget for a while. This forces it.
    private var widgetRefreshButton: some View {
        Button {
            Task {
                isRefreshingWidget = true
                await store.refresh(reason: "widget force refresh")
                WidgetCenter.shared.reloadAllTimelines()
                isRefreshingWidget = false
            }
        } label: {
            Label("Refresh Widget", systemImage: "arrow.2.circlepath")
        }
        .disabled(isRefreshingWidget || store.isLoading)
        .help("Refresh Widget Now — fetches your latest tasks and tells the widget to redraw immediately.")
    }
    #endif
}
