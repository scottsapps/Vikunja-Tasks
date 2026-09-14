//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/AgendaSectionsView.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  AgendaSectionsView.swift
//  VeyrnCalendar
//
//  Renders the sliced day sections shared by both layouts: day header, then all-day chips
//  and event rows in order, with a hairline divider between sections on macOS (§5.6). Each
//  section is wrapped in a `Link` to its own day (§9); the paging chevrons are drawn by the
//  parent as an overlay so they stay outside this `Link` subtree (§7).
//
//  Today is always shown, even with nothing on it ("No Events") — deliberately. Other
//  empty days are still skipped by the grouping.
//

import SwiftUI

struct AgendaSectionsView: View {
    let sections: [DaySection]
    let referenceDay: Date
    let calendar: Calendar
    let metrics: Metrics
    /// Horizontal space to keep clear on the first day's header row for the chevrons.
    var firstHeaderTrailingInset: CGFloat = 0
    /// Page 0 always leads with today ("No Events" if it is empty). A continuation page
    /// (page 1) must not — its first day is wherever `fill` resumed, and today is behind us.
    var leadsWithToday: Bool = true

    /// The real sections; on page 0, guaranteed to start with today (an empty today
    /// section is prepended when today has nothing).
    private var displaySections: [DaySection] {
        guard leadsWithToday else { return sections }
        if let first = sections.first, calendar.isDate(first.day, inSameDayAs: referenceDay) {
            return sections
        }
        return [DaySection(day: referenceDay, items: [])] + sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(displaySections.enumerated()), id: \.offset) { index, section in
                if index > 0 {
                    // No divider straight after an empty day (deliberate).
                    let afterEmpty = displaySections[index - 1].items.isEmpty
                    if metrics.showsDividers && !afterEmpty {
                        Divider()
                            .padding(.top, metrics.sectionSpacingAbove)
                            .padding(.bottom, metrics.sectionSpacingBelow)
                    } else {
                        Color.clear.frame(height: afterEmpty ? metrics.interItemSpacing : metrics.sectionSpacingAbove)
                    }
                }
                daySection(section, trailingInset: index == 0 ? firstHeaderTrailingInset : 0)
            }
        }
    }

    // Not wrapped in a `Link`: the whole widget uses `.widgetURL` so the tap opens Calendar
    // directly on iOS (a widget `Link` to `calshow:` bounces through the container app).
    private func daySection(_ section: DaySection, trailingInset: CGFloat) -> some View {
        let isToday = calendar.isDate(section.day, inSameDayAs: referenceDay)
        return VStack(alignment: .leading, spacing: 0) {
            DayHeaderView(day: section.day, referenceDay: referenceDay, calendar: calendar, metrics: metrics)
                .padding(.trailing, trailingInset)

            if section.items.isEmpty {
                Text("No Events")
                    .font(metrics.emptyDayFont)
                    .foregroundStyle(isToday ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.secondary))
                    .padding(.top, metrics.emptyDayTopGap)
            } else {
                VStack(alignment: .leading, spacing: metrics.interItemSpacing) {
                    // Positional identity, not `item.id`: a boundary item can appear on
                    // both pages (§6.3), and matching it by its stable event id lets
                    // WidgetKit treat the two as "the same view" across the reload,
                    // animating a slide from its old page-0 position to its new page-1
                    // one. Position is unique within a single static render and carries
                    // no such cross-page identity.
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        if item.isAllDay {
                            AllDayChipView(item: item, metrics: metrics)
                        } else {
                            EventRowView(item: item, metrics: metrics)
                        }
                    }
                }
                .padding(.top, metrics.headerRowToBody)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
