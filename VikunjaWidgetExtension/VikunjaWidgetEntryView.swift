import SwiftUI
import WidgetKit

struct VikunjaWidgetEntryView: View {
    let entry: VikunjaEntry
    @Environment(\.widgetFamily) private var family
    /// Still reports the system's default margins after
    /// `.contentMarginsDisabled()`, so every family except medium can put
    /// them back and look exactly as it did before.
    @Environment(\.widgetContentMargins) private var systemMargins

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()  // if even one task overflows, trim it, never the margins
            .padding(contentPadding)
            .containerBackground(.background, for: .widget)
    }

    private var contentPadding: EdgeInsets {
        #if os(macOS)
        return inset(by: 8, 8)
        #else
        switch family {
        // The one family that spends some of the reclaimed margins rather than
        // putting them all back. 12 pt is the balance point, measured: the
        // system's own ~16 pt leaves room for only two tasks on a 338 x 158
        // canvas, while going below ~8 pt buys a fourth task at the cost of
        // margins visibly tighter than Weather's or Fantastical's. 12 pt reads
        // as a normal widget and still fits three tasks on the smallest medium
        // canvas and four on the largest — and the pager reaches the rest.
        case .systemMedium:
            return EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        case .accessoryRectangular, .accessoryCircular, .accessoryInline:
            return systemMargins
        default:
            return inset(by: 8, 12)
        }
        #endif
    }

    /// The system margins plus the family's own extra inset.
    private func inset(by vertical: CGFloat, _ horizontal: CGFloat) -> EdgeInsets {
        EdgeInsets(top: systemMargins.top + vertical,
                   leading: systemMargins.leading + horizontal,
                   bottom: systemMargins.bottom + vertical,
                   trailing: systemMargins.trailing + horizontal)
    }

    @ViewBuilder
    private var content: some View {
        #if os(iOS)
        switch family {
        case .accessoryRectangular:
            accessoryRectangularView
        case .accessoryCircular:
            accessoryCircularView
        case .accessoryInline:
            accessoryInlineView
        default:
            systemContent
        }
        #else
        systemContent
        #endif
    }

    // MARK: - System (large/medium) content

    private var systemContent: some View {
        Group {
            if let error = entry.error {
                errorView(error)
            } else if entry.taskGroups.isEmpty {
                emptyView
            } else {
                taskListView
            }
        }
    }

    // MARK: - Accessory: Rectangular (2 tasks)

    #if os(iOS)
    private var accessoryRectangularView: some View {
        let tasks = entry.taskGroups.flatMap(\.tasks).prefix(2)
        return VStack(alignment: .leading, spacing: 2) {
            if tasks.isEmpty {
                Label("No upcoming tasks", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(tasks)) { task in
                    HStack(spacing: 4) {
                        Circle()
                            .stroke(lineWidth: 1.2)
                            .frame(width: 10, height: 10)
                        Text(task.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    // MARK: - Accessory: Circular (count of today's tasks)

    private var accessoryCircularView: some View {
        let todayCount = entry.todayCount
        return ZStack {
            Circle().strokeBorder(lineWidth: 2).foregroundStyle(.secondary.opacity(0.3))
            VStack(spacing: 0) {
                Text("\(todayCount)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("due")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Accessory: Inline (brief text)

    private var accessoryInlineView: some View {
        let count = entry.todayCount
        if count == 0 {
            return Text("No tasks due today")
        } else {
            return Text("\(count) due today")
        }
    }
    #endif

    // MARK: - Task list (system families)

    /// Shows as many tasks as genuinely fit, measured rather than estimated:
    /// `ViewThatFits` lays out the longest list first and takes the first one
    /// whose height fits the canvas. A points-per-row estimate can't know the
    /// device's widget size or whether a given title wraps, so it had to be
    /// tuned pessimistically — which is how the medium widget ended up showing
    /// two tasks in a canvas that holds four.
    private var taskListView: some View {
        let total = entry.taskGroups.reduce(0) { $0 + $1.tasks.count }
        return ViewThatFits(in: .vertical) {
            ForEach(Array(stride(from: total, through: 1, by: -1)), id: \.self) { limit in
                taskList(limit: limit)
            }
        }
    }

    private func taskList(limit: Int) -> some View {
        let groups = TaskGroup.prefix(entry.taskGroups, limit: limit)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.label) { index, group in
                sectionHeader(group.label, isFirst: index == 0, limit: limit)
                ForEach(Array(group.tasks.enumerated()), id: \.element.id) { row, task in
                    TaskRowView(task: task)
                        .padding(.vertical, 1)
                    // Whatever the canvas has left over after the last row that
                    // fits — up to most of a row — gets shared out between the
                    // rows instead of pooling into one dead band at the bottom.
                    // These have an ideal height of 0, so they don't disturb
                    // the measurement that chose this list in the first place;
                    // they only stretch once it's the one being drawn.
                    if !(index == groups.count - 1 && row == group.tasks.count - 1) {
                        Spacer(minLength: 0).frame(maxHeight: 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func sectionHeader(_ label: String, isFirst: Bool, limit: Int) -> some View {
        HStack(spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            if isFirst, let pager = pager(limit: limit) {
                Spacer(minLength: 8)
                pageButtons(pager, limit: limit)
            }
        }
        .padding(.top, isFirst ? 0 : 8)
        .padding(.bottom, 3)
    }

    // MARK: - Paging

    /// What the pager should offer for a candidate list of `limit` tasks, or
    /// `nil` for no pager at all.
    ///
    /// It earns its place only when a task due **today** got pushed off the
    /// page — a widget whose whole point is today shouldn't spend a control on
    /// "there is more next week". The one exception is the way back: once
    /// you've paged forward, the control stays so you can return.
    ///
    /// Each fit candidate asks this for its own `limit`, so the pager's height
    /// is part of what `ViewThatFits` measures — a list only "fits" if it fits
    /// *with* the control it would draw.
    private struct Pager {
        /// Nil when nothing of today's is hidden — then there is only a way back.
        let hiddenToday: Int?
        let canGoBack: Bool
    }

    private func pager(limit: Int) -> Pager? {
        guard family == .systemMedium || family == .systemLarge else { return nil }
        let todayOnPage = entry.taskGroups.first?.isToday == true
            ? entry.taskGroups[0].tasks.count : 0
        let hiddenToday = todayOnPage - limit
        let canGoBack = entry.pageOffset > 0
        guard hiddenToday > 0 || canGoBack else { return nil }
        return Pager(hiddenToday: hiddenToday > 0 ? hiddenToday : nil, canGoBack: canGoBack)
    }

    @ViewBuilder
    private func pageButtons(_ pager: Pager, limit: Int) -> some View {
        let familyKey = String(describing: family)
        HStack(spacing: 1) {
            if pager.canGoBack {
                Button(intent: ShowPageIntent(familyKey: familyKey, offset: 0, isForward: false)) {
                    pageGlyph { Image(systemName: "chevron.left") }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the previous tasks")
            }
            if let hidden = pager.hiddenToday {
                // Forward moves past exactly what this page shows; where it
                // came from is recorded by the intent, so back is exact.
                Button(intent: ShowPageIntent(familyKey: familyKey,
                                              offset: entry.pageOffset + limit,
                                              isForward: true)) {
                    pageGlyph {
                        Text("+\(hidden)")
                        Image(systemName: "chevron.right")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(hidden) more of today's tasks")
            }
        }
    }

    private func pageGlyph<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    // MARK: - Empty / error

    private var emptyView: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No upcoming tasks")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Couldn't load tasks")
                .font(.subheadline).fontWeight(.medium)
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
