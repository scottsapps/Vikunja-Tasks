import AppIntents
import WidgetKit
import os

private let pageLog = Logger(subsystem: "net.angstreich.VikunjaWidgetApp.VikunjaWidgetExtension", category: "intent")

/// Pages a system-family widget forward (to the page starting at `offset`) or
/// back one page. Purely local view state — no network, and the provider's
/// cache-first path means the redraw is immediate.
struct ShowPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Show More Tasks"

    @Parameter(title: "Family") var familyKey: String
    @Parameter(title: "Offset") var offset: Int
    @Parameter(title: "Forward") var isForward: Bool

    init() {}

    init(familyKey: String, offset: Int, isForward: Bool) {
        self.familyKey = familyKey
        self.offset = offset
        self.isForward = isForward
    }

    func perform() async throws -> some IntentResult {
        pageLog.notice("ShowPageIntent \(familyKey, privacy: .public) \(isForward ? "forward" : "back", privacy: .public)")
        if isForward {
            DiagnosticLog.info("page \(familyKey) → offset \(offset)")
            WidgetPageState.forward(to: offset, for: familyKey)
        } else {
            DiagnosticLog.info("page \(familyKey) → back")
            WidgetPageState.back(for: familyKey)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
