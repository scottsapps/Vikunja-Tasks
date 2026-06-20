import WidgetKit
import Foundation

struct WatchWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> WatchWidgetEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchWidgetEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
            return
        }
        Task { completion(await buildEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchWidgetEntry>) -> Void) {
        Task {
            let entry = await buildEntry()
            // Provide relevance so the Smart Stack surfaces near due times.
            let policy: TimelineReloadPolicy
            if let next = entry.nextTask?.effectiveDueDate {
                policy = .after(next)
            } else {
                let refresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date())!
                policy = .after(refresh)
            }
            completion(Timeline(entries: [entry], policy: policy))
        }
    }

    // MARK: - Build

    private func buildEntry() async -> WatchWidgetEntry {
        // Read from the WidgetCache written by the Watch app after each refresh.
        // This is the fast, battery-friendly path used by the widget timeline.
        if let cached = WidgetCache.load() {
            let sorted = upcoming(from: cached.tasks)
            return WatchWidgetEntry(date: Date(), tasks: sorted, error: nil)
        }
        // If no cache exists, attempt a quick live fetch (first launch).
        guard VikunjaConfig.isConfigured else {
            return WatchWidgetEntry(date: Date(), tasks: [], error: "Open Veyrn on iPhone to set up.")
        }
        do {
            let projects = try await VikunjaAPI.fetchAllProjects()
            let tasks = try await VikunjaAPI.fetchAllUndoneTasks(projects: projects)
            WidgetCache.save(tasks: tasks, projects: projects)
            return WatchWidgetEntry(date: Date(), tasks: upcoming(from: tasks), error: nil)
        } catch {
            return WatchWidgetEntry(date: Date(), tasks: [], error: error.localizedDescription)
        }
    }

    private func upcoming(from tasks: [VikunjaTask]) -> [VikunjaTask] {
        tasks
            .filter { $0.effectiveDueDate != nil }
            .sorted { ($0.effectiveDueDate ?? .distantFuture) < ($1.effectiveDueDate ?? .distantFuture) }
    }
}
