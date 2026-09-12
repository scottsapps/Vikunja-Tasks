//  Vendored from Calvane Widget — Widget/Provider/AgendaEntry.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  AgendaEntry.swift
//  Widget
//

import WidgetKit
import Foundation

struct AgendaEntry: TimelineEntry {
    var date: Date
    var snapshot: AgendaSnapshot
}

extension AgendaEntry {
    /// The gallery / placeholder sample (§10).
    static func sample(referenceDate: Date = .now) -> AgendaEntry {
        AgendaEntry(date: referenceDate, snapshot: .sample(referenceDate: referenceDate))
    }

    static func noAccess(referenceDate: Date = .now) -> AgendaEntry {
        AgendaEntry(
            date: referenceDate,
            snapshot: AgendaSnapshot(
                authorization: .denied, sections: [], page: 0, isContinuation: false,
                canPageBack: false, canPageForward: false,
                referenceDay: Calendar.current.startOfDay(for: referenceDate)
            )
        )
    }
}
