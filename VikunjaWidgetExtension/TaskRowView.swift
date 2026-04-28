import SwiftUI

struct TaskRowView: View {
    let task: TaskEntryItem

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            actionButton
            taskDetails
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if task.isPendingUndo {
            Button(intent: UndoCompleteTaskIntent(taskId: task.id)) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)
        } else {
            Button(intent: CompleteTaskIntent(item: task)) {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.secondary.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 10, height: 10)
            }
            .buttonStyle(.plain)
            .frame(width: 20, height: 20)
        }
    }

    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(task.isPendingUndo ? Color.secondary : Color.primary)
                .strikethrough(task.isPendingUndo, color: .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 5) {
                Text(task.projectName)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                ForEach(task.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
        }
    }
}
