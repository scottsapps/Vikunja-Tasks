//  Vendored from Calvane Widget — Widget/Model/SetPageIntent.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  SetPageIntent.swift
//  Widget
//
//  Writes the target page and reloads (§7). It only writes — it never reads state to
//  decide where to go; the view computes the destination from the current entry and
//  constructs the intent with it.
//

import AppIntents
import WidgetKit

struct SetPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Page"
    static let isDiscoverable: Bool = false

    @Parameter(title: "Page") var page: Int
    @Parameter(title: "Widget Key") var widgetKey: String

    init() {}

    init(page: Int, widgetKey: String) {
        self.page = page
        self.widgetKey = widgetKey
    }

    func perform() async throws -> some IntentResult {
        PageState.set(page, for: widgetKey)
        WidgetCenter.shared.reloadTimelines(ofKind: VeyrnCalendarWidgetKind)
        return .result()
    }
}
