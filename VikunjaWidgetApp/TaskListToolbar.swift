import SwiftUI
import WidgetKit

// Toolbar pieces shared by the three task lists (Inbox, Scheduled, Project) so
// the same actions sit in the same place everywhere. macOS shows each action as
// its own toolbar button; iOS folds the two refreshes into an overflow menu to
// keep the navigation bar from crowding out the title.

private struct TaskListRefreshToolbar: ViewModifier {
    var store: TaskStore

    @State private var isRefreshing = false
    @State private var isRefreshingWidget = false

    func body(content: Content) -> some View {
        content.toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    refreshButton
                    widgetRefreshButton
                } label: {
                    Label("Refresh Options", systemImage: "ellipsis.circle")
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                refreshButton
            }
            ToolbarItem(placement: .primaryAction) {
                widgetRefreshButton
            }
            #endif
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

    // Separate from `refreshButton`: that one just re-fetches into the app,
    // which alone doesn't move the widget along — it's cache-first and only
    // redraws on its own timer or right after an edit made in this app, so a
    // change from elsewhere (the web UI, another device) can sit stale on the
    // widget for a while. This forces it.
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
}

#if os(iOS)
private struct QuickAddToolbarItem: ViewModifier {
    var store: TaskStore
    /// The list being viewed, when it's a project — a task added from here
    /// starts out in that project rather than the Inbox.
    var defaultProject: VikunjaProject?

    @State private var showQuickAdd = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showQuickAdd = true } label: {
                        Label("New Task", systemImage: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showQuickAdd) {
                QuickAddSheet(store: store, defaultProjectId: defaultProject?.id)
            }
    }
}
#endif

extension View {
    /// Refresh + Refresh Widget, in the placement that suits the platform.
    func taskListRefreshToolbar(store: TaskStore) -> some View {
        modifier(TaskListRefreshToolbar(store: store))
    }

    /// The iOS-only New Task button (Mac has one in the window toolbar already).
    func quickAddToolbarItem(store: TaskStore, defaultProject: VikunjaProject? = nil) -> some View {
        #if os(iOS)
        return modifier(QuickAddToolbarItem(store: store, defaultProject: defaultProject))
        #else
        return self
        #endif
    }
}
