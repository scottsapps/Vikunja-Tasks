import SwiftUI

struct TodayView: View {
    var store: TaskStore

    /// Owned here, not by `TaskListView` — the list stays a pure view over whatever it
    /// is handed, so Inbox/Project/Logbook keep passing no events at all.
    @State private var calendar = CalendarEventLoader()

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TaskListView(
            tasks: store.upcomingTasks(),
            mode: .byDate,
            suppressUpcomingDueDate: true,
            events: calendar.eventsByDay
        )
        .navigationTitle("Scheduled")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .quickAddToolbarItem(store: store)
        .taskListRefreshToolbar(store: store)
        .refreshable {
            await store.refresh()
            await calendar.load()
        }
        .task {
            calendar.startObserving()
            await calendar.load()
        }
        // Settings changes (the master switch, the calendar selection, days-ahead) and
        // edits made in Calendar.app while Veyrn was in the background both land here.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await calendar.load() } }
        }
        .overlay {
            if store.isLoading && store.upcomingTasks().isEmpty {
                ProgressView()
            }
        }
    }
}
