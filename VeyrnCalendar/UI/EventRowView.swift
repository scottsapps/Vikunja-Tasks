//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/EventRowView.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  EventRowView.swift
//  VeyrnCalendar
//
//  The shared event row (§5.1):
//
//    ●  6:05 – 8:05 PM  Citizens Bank Park, Philadelphia
//       Atlanta Braves @ Philadelphia Phillies
//
//  Line 1: time (secondary, semibold) then a camera glyph for a video call and/or the
//  location (tertiary, tail-truncated). No location and no video → just the time.
//  Line 2+: title, primary, bold, ≤2 lines, hyphenated.
//
//  Declined invites: the dot becomes a gear glyph and the whole row is dimmed — shown,
//  not hidden. "Maybe" replies get a lighter touch: a hollow dot and a slightly dimmed
//  row, but no glyph swap.
//

import SwiftUI

/// `DateIntervalFormatter` is what produces "6:05 – 8:05 PM" — one period when both ends
/// share it (§5.1). Formatting the two dates separately and joining them is wrong.
private let intervalFormatter: DateIntervalFormatter = {
    let f = DateIntervalFormatter()
    f.dateStyle = .none
    f.timeStyle = .short
    return f
}()

struct EventRowView: View {
    let item: DayItem
    let metrics: Metrics

    private var isDeclined: Bool { item.event.isDeclined }
    /// "Maybe" reply. Declined wins if both are set, so the gear glyph and its deeper
    /// dimming stay unambiguous.
    private var isTentative: Bool { item.event.isTentative && !isDeclined }
    private var isDimmed: Bool { isDeclined || isTentative }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            leadingGlyph
                // Align the dot to the time text's *baseline*, not the line box. An inline
                // video/camera glyph inflates the first line's ascent, and a top-aligned
                // dot would then float above the text on every row that has one (§5.1).
                .alignmentGuide(.firstTextBaseline) { dims in
                    dims[VerticalAlignment.center] + metrics.dotBaselineShift
                }

            VStack(alignment: .leading, spacing: metrics.lineToTitleSpacing) {
                firstLine
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(hyphenated(item.event.title.isEmpty ? " " : item.event.title))
                    .font(metrics.titleFont)
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(metrics.titleLineLimit)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(isDeclined ? 0.7 : (isTentative ? 0.8 : 1))
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        if isDeclined {
            Image(systemName: "gearshape.fill")
                .font(.system(size: metrics.dotDiameter + 2))
                .foregroundStyle(.tertiary)
                .frame(width: metrics.dotDiameter, height: metrics.dotDiameter)
        } else {
            CalendarDot(color: item.event.calendarColor, diameter: metrics.dotDiameter, hollow: isTentative)
        }
    }

    private var firstLine: Text {
        let time = Text(timeText)
            .font(metrics.timeFont)
            .foregroundStyle(.secondary)

        let video: Text = item.event.isVideoConference
            ? Text("  \(Text(Image(systemName: "video.fill")).font(metrics.locationFont).foregroundStyle(.tertiary))")
            : Text(verbatim: "")

        let location: Text
        if let loc = item.event.location, !loc.isEmpty {
            location = Text(verbatim: " \(loc)").font(metrics.locationFont).foregroundStyle(.tertiary)
        } else {
            location = Text(verbatim: "")
        }

        return Text("\(time)\(video)\(location)")
    }

    private var timeText: String {
        if item.isAllDay { return String(localized: "all-day") }
        // The clamped range for the day this row belongs to (multi-day events, §6.2).
        return intervalFormatter.string(from: item.displayStart, to: item.displayEnd)
    }
}

/// Soft hyphenation so long titles break like the reference ("Philadel-phia"). SwiftUI
/// `Text` won't hyphenate on its own; a paragraph style carries it through.
func hyphenated(_ string: String) -> AttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.hyphenationFactor = 1
    paragraph.lineBreakMode = .byWordWrapping
    let ns = NSAttributedString(string: string, attributes: [.paragraphStyle: paragraph])
    return AttributedString(ns)
}
