//
//  EventRow.swift
//  VikunjaWidgetApp
//
//  One calendar event in the Scheduled list.
//
//  **Not** a lift of the widget's `EventRowView` — that one is tuned by `Metrics` for
//  widget density. This is laid out against Things 3's Upcoming, which is what Scott
//  asked for, and the two differ in a way worth stating so nobody "fixes" one into
//  the other:
//
//  - **No calendar dot.** The *time* carries the calendar's colour. A list already has
//    a time column, so a dot would be a third element per row earning nothing. The
//    widget keeps `CalendarDot` — different density, different context.
//  - **All-day events** get a short colour bar where the time would be, not the
//    widget's `AllDayChipView`.
//  - **Lighter than a task.** Tasks are near-primary with a checkbox and a project
//    subtitle; events are secondary with neither, so a day reads as tasks-with-context
//    rather than two competing lists.
//  - **Indented less than a task**, because there is no checkbox gutter to clear.
//
//  Read-only by construction: no tap target, no swipe actions, no editor. Events are
//  not routed through `taskRowOrEditor`, so they cannot acquire any of that by
//  accident.
//

import SwiftUI

struct EventRow: View {
    let item: DayItem

    @Environment(\.fontSizeOffset) private var fs

    private var color: Color { Color(cgColor: item.event.calendarColor.cgColor) }

    /// Declined and "maybe" invites are shown, not hidden — dimmed, and declined more
    /// than tentative so the two stay distinguishable. Same rule as the widget.
    private var isDeclined: Bool { item.event.isDeclined }
    private var isTentative: Bool { item.event.isTentative && !isDeclined }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            leading
            Text(item.event.title.isEmpty ? "(no title)" : item.event.title)
                .font(.system(size: eventTextSize))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .opacity(isDeclined ? 0.55 : (isTentative ? 0.75 : 1))
        // One label for the whole row: VoiceOver should read "2 PM, Standup", not
        // stop on a decorative colour bar.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Leading column (time, or the all-day bar)

    @ViewBuilder
    private var leading: some View {
        if item.isAllDay || item.spansWholeDay {
            // A short colour bar, and the title immediately after it — an all-day row
            // does **not** reserve the time column. Reserving it strands the title
            // further right than the task titles below, which reads as a broken
            // indent. Things 3 does the same: its all-day titles sit well left of its
            // timed ones, and that difference is what makes an all-day row scannable
            // as a different kind of thing.
            Capsule()
                .fill(color)
                .frame(width: 3, height: eventTextSize - 1)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
        } else {
            Text(timeText)
                .font(.system(size: eventTextSize, weight: .regular))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: timeColumnWidth, alignment: .leading)
        }
    }

    /// Deliberately smaller than `TaskRow`'s 13+fs title and larger than its 11+fs
    /// metadata line — measured off the Things 3 reference, where event text runs about
    /// 88% of a task title. Matching the title makes a busy day read as two competing
    /// lists; this makes the events read as context around the tasks.
    private var eventTextSize: CGFloat { 11.5 + CGFloat(fs) }

    /// Wide enough for "12:00 PM" at the current text size, so titles line up down the
    /// day instead of stepping in and out with each time's width.
    private var timeColumnWidth: CGFloat { 55 + CGFloat(fs) * 4 }

    /// `Date.FormatStyle`, so the 12/24-hour choice follows the reader's region —
    /// the same rule the rest of Veyrn follows.
    private var timeText: String {
        item.displayStart.formatted(.dateTime.hour().minute())
    }

    private var accessibilityLabel: String {
        let title = item.event.title.isEmpty ? "Untitled event" : item.event.title
        let when = (item.isAllDay || item.spansWholeDay) ? "All day" : timeText
        if isDeclined { return "\(when), \(title), declined" }
        if isTentative { return "\(when), \(title), maybe" }
        return "\(when), \(title)"
    }
}
