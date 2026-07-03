import SwiftUI

struct FlowLayout: Layout {
    var hSpacing: CGFloat = 8
    var vSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = makeRows(width: proposal.width ?? 10_000, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(rows.count - 1, 0)) * vSpacing
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in makeRows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for sub in row.views {
                sub.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
                x += sub.sizeThatFits(.unspecified).width + hSpacing
            }
            y += row.height + vSpacing
        }
    }

    private struct Row { var views: [LayoutSubview] = []; var height: CGFloat = 0; var width: CGFloat = 0 }

    private func makeRows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            let needed = row.views.isEmpty ? sz.width : row.width + hSpacing + sz.width
            if !row.views.isEmpty && needed > width {
                rows.append(row)
                row = Row()
            }
            if !row.views.isEmpty { row.width += hSpacing }
            row.views.append(sub)
            row.width += sz.width
            row.height = max(row.height, sz.height)
        }
        if !row.views.isEmpty { rows.append(row) }
        return rows
    }
}
