//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/AgendaContentView.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  AgendaContentView.swift
//  VeyrnCalendar
//
//  The reusable widget body: picks the layout by family and handles the no-access state
//  (§10). It is deliberately free of WidgetKit — the widget target wraps this with the
//  interactive paging chevrons and `.widgetURL`, and the app renders it directly in a
//  preview harness for pixel tuning against the reference screenshots.
//

import SwiftUI

/// Which layout to render. Maps 1:1 from `WidgetFamily` in the widget target.
public enum AgendaFamily: Sendable {
    case medium   // iOS, §5.5
    case large    // macOS, §5.6
}

/// Everything the view needs, already sliced for the current page by `fill` (§6.3).
public struct AgendaSnapshot: Sendable, Equatable {
    public var authorization: CalendarAuthorization
    public var sections: [DaySection]
    public var page: Int
    public var isContinuation: Bool
    public var canPageBack: Bool
    public var canPageForward: Bool
    /// Start-of-day of the moment this represents — drives TODAY / TOMORROW and the iOS
    /// left column.
    public var referenceDay: Date

    public init(
        authorization: CalendarAuthorization,
        sections: [DaySection],
        page: Int,
        isContinuation: Bool,
        canPageBack: Bool,
        canPageForward: Bool,
        referenceDay: Date
    ) {
        self.authorization = authorization
        self.sections = sections
        self.page = page
        self.isContinuation = isContinuation
        self.canPageBack = canPageBack
        self.canPageForward = canPageForward
        self.referenceDay = referenceDay
    }

    public var hasAccess: Bool { authorization.canRead }
}

/// True in `.accented` / `.vibrant` widget rendering, where color collapses to one tint
/// (§10). Threaded through the environment so leaf views (dot, chip) can differentiate by
/// shape instead of hue.
public struct AgendaTintOnlyKey: EnvironmentKey {
    public static let defaultValue = false
}

public extension EnvironmentValues {
    var agendaTintOnly: Bool {
        get { self[AgendaTintOnlyKey.self] }
        set { self[AgendaTintOnlyKey.self] = newValue }
    }
}

public struct AgendaContentView: View {
    public let snapshot: AgendaSnapshot
    public let family: AgendaFamily
    public let calendar: Calendar
    /// The widget target passes `false` and overlays its own interactive chevrons; the
    /// in-app harness leaves this `true` to render the static "visible at rest" version.
    public let showsStaticChevrons: Bool

    public init(
        snapshot: AgendaSnapshot,
        family: AgendaFamily,
        calendar: Calendar = .current,
        showsStaticChevrons: Bool = true
    ) {
        self.snapshot = snapshot
        self.family = family
        self.calendar = calendar
        self.showsStaticChevrons = showsStaticChevrons
    }

    public var body: some View {
        let metrics = Metrics.forFamily(family)
        Group {
            if !snapshot.hasAccess {
                NoAccessView(metrics: metrics)
            } else {
                switch family {
                case .large:
                    MacLargeView(snapshot: snapshot, metrics: metrics, calendar: calendar)
                case .medium:
                    MediumView(snapshot: snapshot, metrics: metrics, calendar: calendar)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            // Chevrons show whenever access is granted — disabled, never hidden (§7);
            // in the no-events state both are disabled but still present.
            if showsStaticChevrons && snapshot.hasAccess {
                ChevronPair(canPageBack: snapshot.canPageBack,
                            canPageForward: snapshot.canPageForward,
                            metrics: metrics)
                    .padding(.top, metrics.contentPadding.top - 6)
                    .padding(.trailing, metrics.contentPadding.trailing - 6)
            }
        }
    }
}

/// §10 — brief message plus a tap target that opens the app. No chevrons in this state.
public struct NoAccessView: View {
    let metrics: Metrics
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Calendar access needed")
                .font(metrics.titleFont)
                .foregroundStyle(.primary)
            Text("Tap to open Calvane Widget and grant access.")
                .font(metrics.locationFont)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(metrics.contentPadding)
    }
}
