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
            // Provide relevance so the Smart Stack surfaces near due times, but never
            // schedule a reload in the past (stale cache) or absurdly far out.
            let now = Date()
            let nextDue = entry.nextTask?.effectiveDueDate ?? .distantFuture
            let target = min(nextDue, now.addingTimeInterval(30 * 60))
            let policy: TimelineReloadPolicy = .after(max(target, now.addingTimeInterval(15 * 60)))
            completion(Timeline(entries: [entry], policy: policy))
        }
    }

    // MARK: - Build

    private static let maxCacheAge: TimeInterval = 30 * 60

    private func buildEntry() async -> WatchWidgetEntry {
        // Fast path: a cache written recently (either by the Watch app itself or
        // pushed over from the phone) is trusted without hitting the network.
        if let cached = WidgetCache.load(),
           let savedAt = WidgetCache.savedAt,
           Date().timeIntervalSince(savedAt) < Self.maxCacheAge {
            return WatchWidgetEntry(date: Date(), tasks: upcoming(from: cached.tasks), error: nil)
        }
        guard VikunjaConfig.isConfigured else {
            if let cached = WidgetCache.load() {
                return WatchWidgetEntry(date: Date(), tasks: upcoming(from: cached.tasks), error: nil)
            }
            return WatchWidgetEntry(date: Date(), tasks: [], error: "Open Veyrn on iPhone to set up.")
        }
        do {
            let projects = try await VikunjaAPI.fetchAllProjects()
            let tasks = try await VikunjaAPI.fetchAllUndoneTasks(projects: projects)
            WidgetCache.save(tasks: tasks, projects: projects)
            return WatchWidgetEntry(date: Date(), tasks: upcoming(from: tasks), error: nil)
        } catch {
            // Stale cache beats a blank widget.
            if let cached = WidgetCache.load() {
                return WatchWidgetEntry(date: Date(), tasks: upcoming(from: cached.tasks), error: nil)
            }
            return WatchWidgetEntry(date: Date(), tasks: [], error: error.localizedDescription)
        }
    }

    private func upcoming(from tasks: [VikunjaTask]) -> [VikunjaTask] {
        tasks
            .filter { $0.effectiveDueDate != nil }
            .sorted { ($0.effectiveDueDate ?? .distantFuture) < ($1.effectiveDueDate ?? .distantFuture) }
    }
}
