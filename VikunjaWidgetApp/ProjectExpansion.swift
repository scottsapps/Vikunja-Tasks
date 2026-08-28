import Foundation
import Observation

/// Per-account memory of which projects are expanded in the sidebar and the
/// iPhone project list.
///
/// `UserDefaults.standard`, not the App Group — app-only, like
/// `TaskSortPreferences` and `LaunchPreferences`; no widget or Watch target
/// reads it.
///
/// The key is namespaced by account UUID because **project ids collide across
/// accounts** — two unrelated Vikunja servers both have a project `3`. Without
/// the namespace, switching accounts would apply one server's expansion state
/// to another's projects. Same approach `Outbox` takes with its own keys.
@Observable
final class ProjectExpansion {

    /// The ids of the projects the user has expanded. Storing the **expanded**
    /// set (rather than the collapsed one) keeps collapsed as the quiet
    /// default: a brand-new project, and a first run, start collapsed, and an
    /// empty set is a valid fresh state rather than "everything open".
    private(set) var expanded: Set<Int>

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key: String

    /// `accountId` nil = no active account (fresh install); falls back to an
    /// unsuffixed key, matching `Outbox`.
    init(defaults: UserDefaults = .standard, accountId: UUID?) {
        self.defaults = defaults
        if let accountId {
            self.key = "veyrn.projectExpansion.\(accountId.uuidString)"
        } else {
            self.key = "veyrn.projectExpansion"
        }
        if let stored = defaults.array(forKey: key) as? [Int] {
            self.expanded = Set(stored)
        } else {
            self.expanded = []
        }
    }

    func isExpanded(_ id: Int) -> Bool {
        expanded.contains(id)
    }

    func toggle(_ id: Int) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
        defaults.set(Array(expanded), forKey: key)
    }
}
