//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/CalendarDot.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  CalendarDot.swift
//  VeyrnCalendar
//
//  The filled circle in the owning calendar's color (§5.1–5.2). In accented / vibrant
//  rendering the system flattens color to one tint, so §10 wants a shape difference there —
//  a hollow ring instead of a disc.
//

import SwiftUI

struct CalendarDot: View {
    let color: CodableColor
    let diameter: CGFloat
    /// A "maybe" event: draw the calendar color as a ring, not a disc, so a tentative row
    /// reads as lighter than an accepted one (EventRowView also dims the text).
    var hollow: Bool = false

    @Environment(\.agendaTintOnly) private var tintOnly

    var body: some View {
        Group {
            if tintOnly {
                Circle().strokeBorder(.primary, lineWidth: max(1.5, diameter * 0.22))
            } else if hollow {
                Circle().strokeBorder(Color(cgColor: color.cgColor), lineWidth: max(1.5, diameter * 0.22))
            } else {
                Circle().fill(Color(cgColor: color.cgColor))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}
