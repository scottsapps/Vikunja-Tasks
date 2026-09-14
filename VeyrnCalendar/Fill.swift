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
    /// Index into `DaySection.items` to resume at.
    ///
    /// Normally the first item **not** shown on the previous page. The one exception: a
    /// page that stopped mid-day (its last section hit the budget wall rather than
    /// running out of items) instead points at the **last item shown**, repeating it on
    /// the next page — a hedge against `RowCost` being an estimate, in case that specific
    /// row rendered a hair taller than predicted and clipped (§6.3). A page that stopped
    /// because the *next whole day* didn't fit has no such risk — its last section ran out
    /// of items on its own, a clean fit — so it resumes normally at the dropped day.
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
                // The previous section finished normally (it ran out of its own items,
                // rather than being stopped by the budget), so its last row was a clean
                // fit, not a near miss — nothing there needs repeating. Resume at this
                // section's own start; it was never drawn at all, so there's nothing of
                // it to have clipped.
                nextCursor = Cursor(day: section.day, itemIndex: fromIndex)
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
