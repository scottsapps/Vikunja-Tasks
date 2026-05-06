#if os(iOS)
import Foundation

extension Notification.Name {
    static let vikunjaShortcutFired = Notification.Name("net.angstreich.VikunjaWidgetApp.shortcutFired")
}

@Observable final class ShortcutRouter {
    static let shared = ShortcutRouter()
    private init() {}

    var pendingAction: ShortcutAction?

    enum ShortcutAction: Equatable {
        case newTask
        case today
    }
}
#endif
