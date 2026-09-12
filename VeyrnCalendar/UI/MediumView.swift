//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/MediumView.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  MediumView.swift
//  VeyrnCalendar
//
//  iOS medium (§5.5): ~34% / 66% two columns. Left column is the month / red weekday / big
//  day number and follows the page's first day. Right column is the header row + all-day
//  chips + event rows.
//

import SwiftUI

struct MediumView: View {
    let snapshot: AgendaSnapshot
    let metrics: Metrics
    let calendar: Calendar

    var body: some View {
        let leadDay = snapshot.sections.first?.day ?? snapshot.referenceDay

        GeometryReader { geo in
            let inner = CGSize(
                width: max(0, geo.size.width - metrics.contentPadding.leading - metrics.contentPadding.trailing),
                height: max(0, geo.size.height - metrics.contentPadding.top - metrics.contentPadding.bottom)
            )
            HStack(alignment: .top, spacing: 0) {
                LeftDateColumn(day: leadDay, metrics: metrics, calendar: calendar)
                    .frame(width: inner.width * metrics.leftColumnWidthFraction, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 0) {
                    if snapshot.sections.isEmpty {
                        NoEventsView(metrics: metrics)
                    } else {
                        AgendaSectionsView(
                            sections: snapshot.sections,
                            referenceDay: snapshot.referenceDay,
                            calendar: calendar,
                            metrics: metrics,
                            firstHeaderTrailingInset: 56,
                            leadsWithToday: snapshot.page == 0
                        )
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(metrics.contentPadding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}

struct LeftDateColumn: View {
    let day: Date
    let metrics: Metrics
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(day.formatted(.dateTime.month(.wide)))
                .textCase(.uppercase)
                .font(metrics.monthFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(day.formatted(.dateTime.weekday(.wide)))
                .font(metrics.weekdayFont)
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: metrics.leftColumnTopGap)

            Text(day.formatted(.dateTime.day()))
                .font(metrics.dayNumberFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .fixedSize()
                // A big digit's line box carries empty ascender/descender space; trim the
                // bottom so it sits a little lower in the column (§5.5).
                .padding(.bottom, metrics.dayNumberBottomTrim)
        }
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(.trailing, metrics.leftColumnGutter)
        .clipped()
    }
}

struct NoEventsView: View {
    let metrics: Metrics
    var body: some View {
        Text("No events")
            .font(metrics.titleFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
