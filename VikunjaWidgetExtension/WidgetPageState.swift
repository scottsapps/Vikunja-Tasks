import Foundation

/// Which page of tasks a system-family widget is currently showing.
///
/// This is transient view state, not a preference: the widget's job is
/// today, so a page the user paged to expires and the next reload drops
/// back to the first page. The TTL is deliberately shorter than the
/// provider's 15-minute reload cadence so a widget can never sit on page 2
/// indefinitely with nobody looking.
///
/// Stored per family, because a medium and a large widget on the same device
/// hold different numbers of tasks per page and shouldn't page in lockstep.
/// Plain `UserDefaults` is enough for the same reason `SharedState` gets away
/// with it: the paging intent runs in the widget extension's own process,
/// which is also where the timeline provider reads it back.
enum WidgetPageState {
    static let ttl: TimeInterval = 10 * 60

    static func key(for family: String) -> String { "vikunja_widget_page_\(family)" }

    static func offset(for family: String) -> Int {
        guard isFresh(family) else { return 0 }
        return UserDefaults.standard.integer(forKey: key(for: family))
    }

    /// Moves forward to `offset`, remembering where we came from. Pages hold
    /// different numbers of tasks, so stepping back is only exact if the
    /// previous offset is recorded rather than recomputed.
    static func forward(to offset: Int, for family: String) {
        let previous = WidgetPageState.offset(for: family)  // the parameter shadows the accessor
        var stack = history(for: family)
        stack.append(previous)
        let d = UserDefaults.standard
        d.set(offset, forKey: key(for: family))
        d.set(stack, forKey: key(for: family) + "_history")
        d.set(Date().timeIntervalSince1970, forKey: key(for: family) + "_setAt")
    }

    /// Steps back one page, or to the first page if the history is gone (the
    /// TTL expired, or a build without it wrote the offset).
    static func back(for family: String) {
        var stack = history(for: family)
        let previous = stack.popLast() ?? 0
        guard previous > 0 else { reset(for: family); return }
        let d = UserDefaults.standard
        d.set(previous, forKey: key(for: family))
        d.set(stack, forKey: key(for: family) + "_history")
        d.set(Date().timeIntervalSince1970, forKey: key(for: family) + "_setAt")
    }

    static func reset(for family: String) {
        let d = UserDefaults.standard
        d.removeObject(forKey: key(for: family))
        d.removeObject(forKey: key(for: family) + "_history")
        d.removeObject(forKey: key(for: family) + "_setAt")
    }

    private static func isFresh(_ family: String) -> Bool {
        let setAt = UserDefaults.standard.double(forKey: key(for: family) + "_setAt")
        return setAt > 0 && Date().timeIntervalSince1970 - setAt < ttl
    }

    private static func history(for family: String) -> [Int] {
        guard isFresh(family) else { return [] }
        return UserDefaults.standard.array(forKey: key(for: family) + "_history") as? [Int] ?? []
    }
}
