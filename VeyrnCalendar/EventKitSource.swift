//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/EventKitSource.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation
import EventKit

/// Calendar authorization, mapped off `EKAuthorizationStatus` so the widget's "no access"
/// state (§10) and the app's onboarding have one thing to switch on.
public enum CalendarAuthorization: Sendable, Hashable {
    case notDetermined
    case denied
    case restricted
    case writeOnly
    case fullAccess

    /// Only full access lets us read events. `writeOnly` cannot list calendars or events.
    public var canRead: Bool { self == .fullAccess }
}

/// The production `EventSource` (§6.4). Reads Apple's calendar database directly — spike 0
/// (§4) confirmed the widget extension can do this in its own process on both platforms.
///
/// `Sendable` and cheap to copy: it holds only the config toggles and makes a fresh
/// `EKEventStore` per call (a timeline generation is two calls a few times a day, so the
/// cost is irrelevant, and it keeps the type `Sendable` without locking a shared store).
///
/// Colors are read fresh on every call — a color change in Calendar.app is not reliably an
/// event change, so a cached color goes stale (§5.2).
public struct EventKitSource: EventSource {
    /// Include all-day events (§11 `showAllDay`, default true).
    public var includeAllDay: Bool
    /// Include events the current user has declined. Default true: they appear **dimmed**
    /// (deliberate, §6.2); the config can hide them entirely (§11).
    public var includeDeclined: Bool

    public init(includeAllDay: Bool = true, includeDeclined: Bool = true) {
        self.includeAllDay = includeAllDay
        self.includeDeclined = includeDeclined
    }

    /// Current calendar authorization, without prompting. The widget never requests access;
    /// the app does (§10).
    public static var authorization: CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .writeOnly: return .writeOnly
        case .fullAccess, .authorized: return .fullAccess
        @unknown default: return .denied
        }
    }

    public func events(from: Date, to: Date, calendarIDs: [String]?) async throws -> [AgendaEvent] {
        guard Self.authorization.canRead else { throw EventSourceError.notAuthorized }
        let store = EKEventStore()

        let calendars: [EKCalendar]?
        if let calendarIDs {
            let wanted = Set(calendarIDs)
            calendars = store.calendars(for: .event).filter { wanted.contains($0.calendarIdentifier) }
            // An explicit, non-empty selection that resolves to nothing → show nothing,
            // rather than falling through to "all calendars".
            if calendars?.isEmpty == true { return [] }
        } else {
            calendars = nil
        }

        let predicate = store.predicateForEvents(withStart: from, end: max(from, to), calendars: calendars)
        let ekEvents = store.events(matching: predicate)

        return ekEvents.compactMap { ekEvent in
            guard ekEvent.status != .canceled else { return nil }
            guard includeAllDay || !ekEvent.isAllDay else { return nil }
            guard includeDeclined || !Self.isDeclinedByCurrentUser(ekEvent) else { return nil }
            return AgendaEvent(ekEvent)
        }
    }

    public func calendars() async throws -> [CalendarInfo] {
        guard Self.authorization.canRead else { throw EventSourceError.notAuthorized }
        let store = EKEventStore()
        return store.calendars(for: .event)
            .map(CalendarInfo.init)
            .sorted(by: CalendarInfo.pickerOrder)
    }

    // MARK: - Event classification

    static func isDeclinedByCurrentUser(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    /// The current user answered "maybe". Always shown (no config toggle), just dimmed.
    static func isTentativeByCurrentUser(_ event: EKEvent) -> Bool {
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .tentative }
    }

    /// Hosts whose links mean "this is a video call".
    static let videoConferenceHosts = [
        "zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com",
        "webex.com", "whereby.com", "meet.jit.si", "around.co", "chime.aws",
        "gotomeeting.com", "bluejeans.com", "skype.com", "hangouts.google.com",
        "vsee.com", "8x8.vc", "pop.com", "riverside.fm",
    ]

    /// Does the event carry a video-conference link anywhere (location, URL, notes)?
    static func hasVideoConference(_ event: EKEvent) -> Bool {
        let hay = [event.location, event.url?.absoluteString, event.notes]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return videoConferenceHosts.contains { hay.contains($0) }
    }

    /// Is this string, on its own, a video-conference URL (so the row should show a camera
    /// glyph instead of the raw link)?
    static func isVideoConferenceURL(_ string: String?) -> Bool {
        guard let s = string?.lowercased(), s.hasPrefix("http") else { return false }
        return videoConferenceHosts.contains { s.contains($0) }
    }
}

extension AgendaEvent {
    /// Flatten an `EKEvent`. Not public — `EKEvent` must not cross `VeyrnCalendar`'s API (§3).
    init(_ event: EKEvent) {
        // Recurring occurrences share one `eventIdentifier`; disambiguate with the start.
        let base = event.eventIdentifier ?? UUID().uuidString
        let occurrence = Int(event.startDate.timeIntervalSinceReferenceDate.rounded())

        let rawLocation = (event.structuredLocation?.title ?? event.location)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLocation = (rawLocation?.isEmpty ?? true) ? nil : rawLocation

        // A location that is *only* a video URL becomes the camera glyph, no text.
        let locationIsVideo = EventKitSource.isVideoConferenceURL(trimmedLocation)

        self.init(
            id: "\(base)@\(occurrence)",
            title: event.title ?? "",
            location: locationIsVideo ? nil : trimmedLocation,
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarColor: CodableColor(cgColor: event.calendar.cgColor),
            calendarID: event.calendar.calendarIdentifier,
            isVideoConference: EventKitSource.hasVideoConference(event),
            isDeclined: EventKitSource.isDeclinedByCurrentUser(event),
            isTentative: EventKitSource.isTentativeByCurrentUser(event)
        )
    }
}

public extension CalendarInfo {
    /// Flatten an `EKCalendar`.
    init(_ calendar: EKCalendar) {
        self.init(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            sourceTitle: calendar.source?.title ?? "",
            color: CodableColor(cgColor: calendar.cgColor)
        )
    }
}
