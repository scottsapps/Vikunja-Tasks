import Foundation

// Shared cache between the app and widget extension, stored in the App Group container.
// Both processes write here on a successful fetch; the widget reads it as a fallback when offline.
enum WidgetCache {
    private static let suiteName = "group.net.angstreich.VikunjaWidgetApp"
    private static let tasksKey = "widget.cache.tasks"
    private static let projectsKey = "widget.cache.projects"
    private static let savedAtKey = "widget.cache.savedAt"

    static func save(tasks: [VikunjaTask], projects: [VikunjaProject]) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(try? JSONEncoder().encode(tasks), forKey: tasksKey)
        defaults.set(try? JSONEncoder().encode(projects), forKey: projectsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: savedAtKey)
    }

    static var savedAt: Date? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        let t = defaults.double(forKey: savedAtKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    static func load() -> (tasks: [VikunjaTask], projects: [VikunjaProject])? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let taskData = defaults.data(forKey: tasksKey),
              let tasks = try? JSONDecoder().decode([VikunjaTask].self, from: taskData),
              let projectData = defaults.data(forKey: projectsKey),
              let projects = try? JSONDecoder().decode([VikunjaProject].self, from: projectData)
        else { return nil }
        return (tasks, projects)
    }

    /// Wipes the cache on an account switch so a widget can't show the
    /// previous account's tasks (or complete one of its tasks against the
    /// new account's server) before the post-switch refresh repopulates it.
    static func clear() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removeObject(forKey: tasksKey)
        defaults.removeObject(forKey: projectsKey)
        defaults.removeObject(forKey: savedAtKey)
    }
}
