import SwiftUI

struct ParsedChips: View {
    let result: QuickAddResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            chip(result.cleanedTitle, color: .primary)
            if let due = result.dueDate {
                chip(due.formatted(.dateTime.month(.abbreviated).day()), color: .blue)
            }
            if let project = result.projectName {
                chip("+\(project)", color: .green)
            }
            if let priority = result.priority {
                chip("!\(priority)", color: .orange)
            }
            ForEach(result.labelTitles, id: \.self) { tag in
                chip("*\(tag)", color: .purple)
            }
        }
    }

    @ViewBuilder
    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .lineLimit(1)
    }
}
