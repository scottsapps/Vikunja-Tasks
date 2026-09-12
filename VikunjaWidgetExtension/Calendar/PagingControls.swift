//  Vendored from Calvane Widget — Widget/Views/PagingControls.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  PagingControls.swift
//  Widget
//
//  The two chevrons in the upper right (§7). Disabled, never hidden — chrome that moves
//  between reloads reads as broken. Rendered by the parent as an overlay so they sit
//  OUTSIDE any day `Link` subtree (§7 hit-testing trap).
//

import SwiftUI
import WidgetKit
import AppIntents

struct PagingControls: View {
    let page: Int
    let canPageBack: Bool
    let canPageForward: Bool
    let widgetKey: String
    let metrics: Metrics

    var body: some View {
        HStack(spacing: metrics.chevronSpacing) {
            chevron(system: "chevron.left", enabled: canPageBack, destination: page - 1)
            chevron(system: "chevron.right", enabled: canPageForward, destination: page + 1)
        }
    }

    private func chevron(system: String, enabled: Bool, destination: Int) -> some View {
        Button(intent: SetPageIntent(page: destination, widgetKey: widgetKey)) {
            Image(systemName: system)
                .font(metrics.chevronFont)
                .foregroundStyle(enabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
