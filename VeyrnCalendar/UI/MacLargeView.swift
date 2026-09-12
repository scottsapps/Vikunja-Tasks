//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/MacLargeView.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  MacLargeView.swift
//  VeyrnCalendar
//
//  macOS / iOS large (§5.6): single-column multi-day agenda, no month block. Hairline
//  divider between day sections, none above the first. Empty days are skipped by the
//  grouping (except today — always shown, prepended by the provider).
//
//  The content is hard-pinned to the widget's real size and top-aligned, so if `fill`
//  ever over-fills the overflow clips at the *bottom* only — WidgetKit centre-clips an
//  oversized child, which would eat the top header too.
//

import SwiftUI

struct MacLargeView: View {
    let snapshot: AgendaSnapshot
    let metrics: Metrics
    let calendar: Calendar

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                if snapshot.sections.isEmpty {
                    NoEventsView(metrics: metrics)
                } else {
                    AgendaSectionsView(
                        sections: snapshot.sections,
                        referenceDay: snapshot.referenceDay,
                        calendar: calendar,
                        metrics: metrics,
                        firstHeaderTrailingInset: 52,
                        leadsWithToday: snapshot.page == 0
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(metrics.contentPadding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}
