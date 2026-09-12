//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/AllDayChipView.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  AllDayChipView.swift
//  VeyrnCalendar
//
//  The all-day chip (§5.3): a rounded rectangle filled with the calendar color, white bold
//  text, sized to its content — it does NOT stretch to full width.
//

import SwiftUI

struct AllDayChipView: View {
    let item: DayItem
    let metrics: Metrics

    @Environment(\.agendaTintOnly) private var tintOnly

    var body: some View {
        HStack(spacing: 0) {
            label
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var label: some View {
        let text = Text(item.event.title.isEmpty ? " " : item.event.title)
            .font(metrics.chipFont)
            .lineLimit(1)

        if tintOnly {
            // Outline instead of fill so chips stay distinct when color collapses (§10).
            text
                .foregroundStyle(.primary)
                .padding(metrics.chipPadding)
                .overlay(
                    RoundedRectangle(cornerRadius: metrics.chipCornerRadius, style: .continuous)
                        .strokeBorder(.primary, lineWidth: 1.5)
                )
        } else {
            text
                .foregroundStyle(.white)
                .padding(metrics.chipPadding)
                .background(
                    Color(cgColor: item.event.calendarColor.cgColor),
                    in: RoundedRectangle(cornerRadius: metrics.chipCornerRadius, style: .continuous)
                )
        }
    }
}
