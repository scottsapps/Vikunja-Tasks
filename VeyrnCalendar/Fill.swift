//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/Fill.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation
import CoreGraphics

/// Where a page stopped: the day and the index into that day's ordered items (§6.3).
/// Persisted across processes (the paging intent writes it in one process, the provider
/// reads it in another), hence `Codable`.
public struct Cursor: Codable, Hashable, Sendable {
    /// Start of day, in the grouping calendar.
    public let day: Date
    /// Index into `DaySection.items` to resume at. This is the **last item shown** on the
    /// previous page, not the first unseen one — repeating it on the next page is a
    /// deliberate hedge against `RowCost` being an estimate: if that row rendered a hair
    /// taller than predicted and clipped, it's guaranteed to reappear in full (§6.3).
    public let itemIndex: Int

    public init(day: Date, itemIndex: Int) {
        self.day = day
        self.itemIndex = itemIndex
    }
}

/// Per-row height estimates, in points, used by `fill` to decide what fits (§6.3). Starting
/// values are the plan's; the real numbers get tuned against the reference screenshots and
/// live in the widget's `Metrics` (§5.7). `fill` never measures real text — it approximates
/// title wrapping from `titleCharsPerLine`.
public struct RowCost: Hashable, Sendable {
    public var dayHeader: CGFloat
    public var allDayChip: CGFloat
    /// A row whose title fits on one line (time/location line + one title line).
    public var eventRow: CGFloat
    /// A row whose title wraps to two lines (the max, §5.1).
    public var eventRow3: CGFloat
    public var divider: CGFloat
    /// Approximate characters that fit on one title line at the target column width.
    public var titleCharsPerLine: Int

    public init(
        dayHeader: CGFloat = 20,
        allDayChip: CGFloat = 24,
        eventRow: CGFloat = 38,
        eventRow3: CGFloat = 56,
        divider: CGFloat = 13,
        titleCharsPerLine: Int = 34
    ) {
        self.dayHeader = dayHeader
        self.allDayChip = allDayChip
        self.eventRow = eventRow
        self.eventRow3 = eventRow3
        self.divider = divider
        self.titleCharsPerLine = titleCharsPerLine
    }

    /// macOS large / iOS large: single wide column (§5.6). Tighter than the defaults to
    /// match the target row density.
    // Values roughly include the spacing that follows each element, so `fillBudget` can be
    // close to the widget's real usable height (widget height − top/bottom contentPadding).
    public static let macOSLarge = RowCost(
        dayHeader: 21, allDayChip: 22, eventRow: 34, eventRow3: 49, divider: 12,
        titleCharsPerLine: 47
    )
    /// iOS medium: the ~65%-width right column (§5.5).
    public static let iOSMedium = RowCost(
        dayHeader: 19, allDayChip: 23, eventRow: 37, eventRow3: 56, divider: 12,
        titleCharsPerLine: 25
    )
}

/// One page's worth of sections plus where to resume.
public struct Page: Sendable, Equatable {
    public let sections: [DaySection]
    /// `nil` means everything fits — the forward chevron is disabled (§7).
    public let nextCursor: Cursor?
    /// This page began part-way through a day, so its first section's header is a repeat
    /// of the previous page's (§6.3). The view may show a subtle continuation cue.
    public let isContinuation: Bool

    public init(sections: [DaySection], nextCursor: Cursor?, isContinuation: Bool) {
        self.sections = sections
        self.nextCursor = nextCursor
        self.isContinuation = isContinuation
    }

    public static let empty = Page(sections: [], nextCursor: nil, isContinuation: false)
}

/// Slices grouped day sections to a vertical budget (§6.3) — "the most important function in
/// the project". SwiftUI clipping renders half-rows, so this computes what fits, then the
/// view renders exactly that.
///
/// Pure: no EventKit, no `Date()`, no defaults. `calendar` and `cost` are passed in (the
/// plan's sketch signature took only `from/budget/events`; the calendar is required for
/// grouping and `cost` carries the §6.3 constants, both defaulted).
///
/// - `cursor == nil` → page 0, from the top.
/// - `cursor != nil` → page 1, resuming at `cursor.day` / `cursor.itemIndex`; if that day
///   split across the boundary its header is repeated (`isContinuation == true`).
/// - A stale cursor (its day no longer present) resumes at the first later day.
public func fill(
    from cursor: Cursor?,
    budget: CGFloat,
    events: [AgendaEvent],
    calendar: Calendar,
    cost: RowCost = RowCost()
) -> Page {
    let sections = DayGrouping.sections(for: events, in: calendar)
    return fill(from: cursor, budget: budget, sections: sections, cost: cost)
}

/// Same as `fill(from:budget:events:calendar:cost:)` but takes already-grouped sections —
/// useful when the caller has grouped once and wants to page without regrouping.
public func fill(
    from cursor: Cursor?,
    budget: CGFloat,
    sections allSections: [DaySection],
    cost: RowCost = RowCost()
) -> Page {
    guard !allSections.isEmpty else { return .empty }

    // Resolve the starting position.
    let startSection: Int
    let startItem: Int
    let isContinuation: Bool
    if let cursor {
        if let exact = allSections.firstIndex(where: { $0.day == cursor.day }) {
            startSection = exact
            startItem = min(max(0, cursor.itemIndex), allSections[exact].items.count)
            isContinuation = startItem > 0
        } else if let later = allSections.firstIndex(where: { $0.day > cursor.day }) {
            startSection = later
            startItem = 0
            isContinuation = false
        } else {
            return .empty // cursor is past everything
        }
    } else {
        startSection = 0
        startItem = 0
        isContinuation = false
    }

    var used: CGFloat = 0
    var out: [DaySection] = []
    var nextCursor: Cursor?

    sections: for s in startSection..<allSections.count {
        let section = allSections[s]
        let fromIndex = (s == startSection) ? startItem : 0
        guard fromIndex < section.items.count else { continue }

        let headerBlock = (out.isEmpty ? 0 : cost.divider) + cost.dayHeader
        let firstItemCost = itemCost(section.items[fromIndex], cost: cost)

        // Drop a section whose header would fit but whose first item would not (§6.3).
        if used + headerBlock + firstItemCost > budget {
            if out.isEmpty {
                // Never hand back a blank page 1: force the header + first item.
                out.append(DaySection(day: section.day, items: [section.items[fromIndex]]))
                let next = fromIndex + 1
                if next < section.items.count {
                    nextCursor = Cursor(day: section.day, itemIndex: next)
                } else if s + 1 < allSections.count {
                    nextCursor = Cursor(day: allSections[s + 1].day, itemIndex: 0)
                }
            } else {
                // Re-show the last item that *did* fit rather than resuming at this
                // dropped section: `cost` is an estimate, so the row that estimate
                // decided fit may have rendered a hair taller than predicted and clipped
                // at the real widget edge. Repeating it guarantees it's never lost, even
                // when it wasn't actually clipped (§6.3).
                nextCursor = lastShown(in: out)
            }
            break sections
        }

        used += headerBlock
        var taken: [DayItem] = []
        var idx = fromIndex
        while idx < section.items.count {
            let c = itemCost(section.items[idx], cost: cost)
            if used + c > budget {
                // Same reasoning: back up to the last item that fit (always `idx - 1`
                // here — the pre-check above guarantees `fromIndex` itself fit).
                nextCursor = Cursor(day: section.day, itemIndex: idx - 1)
                break
            }
            used += c
            taken.append(section.items[idx])
            idx += 1
        }
        out.append(DaySection(day: section.day, items: taken))
        if nextCursor != nil { break sections }
    }

    return Page(sections: out, nextCursor: nextCursor, isContinuation: isContinuation)
}

/// A cursor pointing back at the last item actually placed in `out` — used to repeat a
/// page's final row on the next page (§6.3). `out` only ever holds non-empty sections
/// (a forced section always keeps its one item), so `out.last` always has an item.
private func lastShown(in out: [DaySection]) -> Cursor? {
    guard let last = out.last, let lastItemIndex = last.items.indices.last else { return nil }
    return Cursor(day: last.day, itemIndex: lastItemIndex)
}

/// Predicted height of one item.
func itemCost(_ item: DayItem, cost: RowCost) -> CGFloat {
    if item.isAllDay { return cost.allDayChip }
    return predictedTitleLines(item.event.title, charsPerLine: cost.titleCharsPerLine) >= 2
        ? cost.eventRow3
        : cost.eventRow
}

/// Chars-per-line approximation of title wrapping, capped at 2 lines (§5.1). Upgrade to
/// `NSAttributedString.boundingRect` only if rows visibly clip (§6.3).
func predictedTitleLines(_ title: String, charsPerLine: Int) -> Int {
    guard charsPerLine > 0 else { return 1 }
    let count = title.trimmingCharacters(in: .whitespacesAndNewlines).count
    guard count > 0 else { return 1 }
    return max(1, min(2, Int((Double(count) / Double(charsPerLine)).rounded(.up))))
}
