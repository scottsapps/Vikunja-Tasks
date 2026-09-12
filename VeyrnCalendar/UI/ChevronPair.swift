//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/ChevronPair.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  ChevronPair.swift
//  VeyrnCalendar
//
//  The paging chevrons' appearance (§7): `chevron.left` / `chevron.right`, secondary label
//  color, tertiary when disabled, with a ≥28pt hit frame. This is the *visual* only — the
//  widget target overlays tappable `Button(intent:)`s with the same geometry; the in-app
//  harness shows this static version so "visible at rest" is verifiable.
//

import SwiftUI

public struct ChevronPair: View {
    let canPageBack: Bool
    let canPageForward: Bool
    let metrics: Metrics

    public init(canPageBack: Bool, canPageForward: Bool, metrics: Metrics) {
        self.canPageBack = canPageBack
        self.canPageForward = canPageForward
        self.metrics = metrics
    }

    public var body: some View {
        HStack(spacing: metrics.chevronSpacing) {
            glyph("chevron.left", enabled: canPageBack)
            glyph("chevron.right", enabled: canPageForward)
        }
    }

    private func glyph(_ name: String, enabled: Bool) -> some View {
        Image(systemName: name)
            .font(metrics.chevronFont)
            .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .frame(minWidth: 28, minHeight: 28)
            .contentShape(Rectangle())
    }
}
