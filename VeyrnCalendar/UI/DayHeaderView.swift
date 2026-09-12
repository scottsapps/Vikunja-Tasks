//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/DayHeaderView.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  DayHeaderView.swift
//  VeyrnCalendar
//
//  The day header (§5.4).
//
//  macOS large  → "TODAY SATURDAY 9/5/26" — leading word + weekday (blue for today, else
//                 primary), then a secondary-gray date suffix that is not uppercase.
//  iOS medium   → just "TODAY" / "TOMORROW" (the weekday and day number live in the left
//                 column, §5.4/§5.5); later days fall back to the weekday alone.
//
//  Blue is reserved for today (§5.4); on page 2, if today isn't visible, no header is blue.
//

import SwiftUI

struct DayHeaderView: View {
    let day: Date
    let referenceDay: Date
    let calendar: Calendar
    let metrics: Metrics

    private enum Relation { case today, tomorrow, later }

    private var relation: Relation {
        let days = calendar.dateComponents([.day], from: referenceDay, to: calendar.startOfDay(for: day)).day ?? 0
        switch days {
        case 0: return .today
        case 1: return .tomorrow
        default: return .later
        }
    }

    private var weekday: String {
        day.formatted(.dateTime.weekday(.wide)).uppercased()
    }

    private var dateSuffix: String {
        day.formatted(.dateTime.month(.defaultDigits).day().year(.twoDigits))
    }

    /// The main (blue-or-primary) portion of the header.
    private var leadText: String {
        let word: String? = switch relation {
        case .today: String(localized: "TODAY")
        case .tomorrow: String(localized: "TOMORROW")
        case .later: nil
        }
        if metrics.compactHeader {
            return word ?? weekday
        }
        return [word, weekday].compactMap { $0 }.joined(separator: " ")
    }

    var body: some View {
        let lead = Text(leadText)
            .font(metrics.headerFont)
            .kerning(metrics.headerKerning)
            .foregroundStyle(relation == .today ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.primary))

        let suffix: Text = metrics.showsDateSuffix
            ? Text(verbatim: " \(dateSuffix)").font(metrics.dateSuffixFont).foregroundStyle(.secondary)
            : Text(verbatim: "")

        return Text("\(lead)\(suffix)").lineLimit(1)
    }
}
