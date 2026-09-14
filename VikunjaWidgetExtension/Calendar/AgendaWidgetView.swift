//  Vendored from Calvane Widget — Widget/Views/AgendaWidgetView.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  AgendaWidgetView.swift
//  Widget
//
//  Thin widget wrapper: renders AgendaKit's AgendaContentView, overlays the interactive
//  paging chevrons outside the day-`Link` subtree (§7), and sets the widget-wide URL.
//

import SwiftUI
import WidgetKit
import AppIntents

struct AgendaWidgetView: View {
    var entry: AgendaEntry

    @Environment(\.widgetFamily) private var widgetFamily
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var family: AgendaFamily {
        (widgetFamily == .systemLarge || widgetFamily == .systemExtraLarge) ? .large : .medium
    }

    private var cornerHitInset: CGFloat {
        #if os(macOS)
        Metrics.forFamily(family).chevronHitInset
        #else
        0
        #endif
    }

    var body: some View {
        let metrics = Metrics.forFamily(family)
        let snapshot = entry.snapshot

        AgendaContentView(snapshot: snapshot, family: family, showsStaticChevrons: false)
            .environment(\.agendaTintOnly, renderingMode != .fullColor)
            // iOS: the whole surface is the Calendar tap target. A Button running an
            // AppIntent — not a Link — because only the intent's OpenURLIntent result
            // reaches Calendar directly; a Link (or .widgetURL) just launches Veyrn.
            // macOS has no `calshow:` handler at all, so it stays on the app relay below,
            // which now routes through Veyrn's own `vikunja://` scheme.
            .modifier(OpenCalendarTapTarget(day: snapshot.referenceDay, enabled: snapshot.hasAccess))
            .overlay(alignment: .topTrailing) {
                if snapshot.hasAccess {
                    PagingControls(
                        page: snapshot.page,
                        canPageBack: snapshot.canPageBack,
                        canPageForward: snapshot.canPageForward,
                        widgetKey: VeyrnCalendarWidgetKind + ".\(widgetFamily)",
                        metrics: metrics
                    )
                    // macOS desktop/Notification Center widgets reserve their extreme
                    // corner for the system's own hover chrome (Edit Widget affordance);
                    // a tap target flush against that corner can be swallowed before it
                    // ever reaches our Button. `contentMarginsDisabled()` (Widget.swift)
                    // opts out of the system's default margin that would normally hold
                    // content clear of it, so pull the forward chevron in by
                    // `chevronHitInset` on macOS only — iOS has no such corner chrome and
                    // stays pixel-identical.
                    .padding(.top, metrics.contentPadding.top - 6 + cornerHitInset)
                    .padding(.trailing, metrics.contentPadding.trailing - 6 + cornerHitInset)
                }
            }
            .widgetURL(snapshot.hasAccess ? dayDeepLink(snapshot.referenceDay) : calendarSettingsDeepLink)
    }
}

/// Makes the widget body a Calendar tap target. The chevrons are overlaid *outside* this
/// modifier's subtree so their own intents still win the tap (§7).
private struct OpenCalendarTapTarget: ViewModifier {
    let day: Date
    let enabled: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        // iOS 18+ reaches Calendar with no app hop. On 17 there is no `OpenURLIntent`,
        // so the `.widgetURL` on the body does the work instead and the tap relays
        // through Veyrn — see `OpenCalendarIntent`.
        if enabled, #available(iOS 18.0, *) {
            Button(intent: OpenCalendarIntent(day: day)) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
        #endif
    }
}
