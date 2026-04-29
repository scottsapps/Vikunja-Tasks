import SwiftUI

struct TaskRow: View {
    let task: VikunjaTask
    let projectName: String
    var onTap: (() -> Void)? = nil
    let onComplete: () -> Void

    @State private var isCompleting = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            checkboxButton
            taskDetails
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .cornerRadius(6)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .onAppear { isCompleting = false }
    }

    // MARK: - Checkbox

    private var checkboxButton: some View {
        Button {
            guard !isCompleting else { return }
            isCompleting = true
            withAnimation(.easeIn(duration: 0.15)) {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                onComplete()
            }
        } label: {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                if isCompleting {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .animation(.easeInOut(duration: 0.15), value: isCompleting)
    }

    // MARK: - Task details

    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(.system(size: 13))
                .foregroundStyle(isCompleting ? .secondary : .primary)
                .strikethrough(isCompleting, color: .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Text(projectName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ForEach(task.labels ?? [], id: \.id) { label in
                    Text(label.title)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }

                if let due = task.effectiveDueDate {
                    dueDateLabel(due)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    private func dueDateLabel(_ date: Date) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let taskDay = cal.startOfDay(for: date)
        let isOverdue = taskDay < today

        let label: String
        if taskDay == today { label = "Today" }
        else if taskDay == cal.date(byAdding: .day, value: 1, to: today)! { label = "Tomorrow" }
        else if isOverdue { label = "Overdue" }
        else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            label = fmt.string(from: date)
        }

        return Text(label)
            .font(.system(size: 10))
            .foregroundStyle(isOverdue ? .red : .secondary)
    }

    // MARK: - Background

    @ViewBuilder
    private var rowBackground: some View {
        #if os(macOS)
        if isHovered {
            Color.primary.opacity(0.05)
        } else {
            Color.clear
        }
        #else
        Color.clear
        #endif
    }
}

// MARK: - Logbook row (done tasks)

struct LogbookRow: View {
    let task: VikunjaTask
    let projectName: String
    let onReopen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.secondary.opacity(0.5))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .strikethrough(true, color: .secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(projectName)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    if let updated = task.updatedDate {
                        Text(updated, style: .relative)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                onReopen()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reopen task")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
    }
}
