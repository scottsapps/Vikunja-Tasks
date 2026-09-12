//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/EventSource.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation

/// The seam between "where events come from" and everything that renders them. The views
/// and the timeline provider only ever see this protocol, never a concrete type (§6.4).
///
/// Spike 0 (§4) resolved in favour of the direct path, so the only production conformer is
/// `EventKitSource`. `FakeEventSource` backs tests and SwiftUI previews. The protocol still
/// exists so that decision stays swappable.
public protocol EventSource: Sendable {
    /// Events overlapping `[from, to)`, optionally restricted to the given calendar
    /// identifiers (`nil` means every calendar the user granted). Multi-day events whose
    /// span merely touches the window are included; day-splitting is the grouping layer's
    /// job (§6.2), not the source's.
    func events(from: Date, to: Date, calendarIDs: [String]?) async throws -> [AgendaEvent]

    /// Every event calendar currently visible to the process, for the config picker (§11).
    func calendars() async throws -> [CalendarInfo]
}

/// Errors an `EventSource` can surface. `EventKitSource` maps EventKit's authorization
/// states onto these so the widget's "no access" state (§10) has something concrete to
/// switch on.
public enum EventSourceError: Error, Equatable, Sendable {
    /// The user has never been asked, or asked and refused, or access is restricted.
    case notAuthorized
    /// Authorized, but the underlying store failed the request.
    case storeUnavailable
}
