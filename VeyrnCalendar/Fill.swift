//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/Fill.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Where a page stopped: the day and the index into that day's ordered items (§6.3).
/// Persisted across processes (the paging intent writes it in one process, the provider
/// reads it in another), hence `Codable`.
public struct Cursor: Codable, Hashable, Sendable {
    /// Start of day, in the grouping calendar.
    public let day: Date
    /// Index into `DaySection.items` — the first item **not** shown on the previous page.
    public let itemIndex: Int

    public init(day: Date, itemIndex: Int) {
        self.day = day
        self.itemIndex = itemIndex
    }
}

/// Per-row height estimates, in points, used by `fill` to decide what fits (§6.3). Starting
/// values are the plan's; the real numbers get tuned against the reference screenshots and
/// live in the widget's `Metrics` (§5.7). Title wrapping is measured for real
/// (`measuredTitleLines`), not guessed by character count — a character-count guess
/// systematically under-counted capital/punctuation-heavy titles (real bug, 2026-09: a
/// 42-character title under the old 47-char threshold still wrapped to 2 lines and clipped).
public struct RowCost: Hashable, Sendable {
    public var dayHeader: CGFloat
    public var allDayChip: CGFloat
    /// A row whose title fits on one line (time/location line + one title line).
    public var eventRow: CGFloat
    /// A row whose title wraps to two lines (the max, §5.1).
    public var eventRow3: CGFloat
    public var divider: CGFloat
    /// Title font point size, for measuring real wrap. Must match the corresponding
    /// `Metrics.titleFont`'s size — the title is always bold (§5.1).
    public var titleFontPointSize: CGFloat
    /// Available width for the title line, in points. Deliberately conservative (narrower
    /// than the real column) so a borderline title is more likely measured as 2 lines than
    /// 1 — wasting a little vertical budget on a title that would actually have fit is
    /// safe; undercounting it and clipping is not (§6.3). Tune against real screenshots
    /// like the other constants here, not by exact widget-frame math.
    public var titleMeasureWidth: CGFloat

    public init(
        dayHeader: CGFloat = 20,
        allDayChip: CGFloat = 24,
        eventRow: CGFloat = 38,
        eventRow3: CGFloat = 56,
        divider: CGFloat = 13,
        titleFontPointSize: CGFloat = 13,
        titleMeasureWidth: CGFloat = 280
    ) {
        self.dayHeader = dayHeader
        self.allDayChip = allDayChip
        self.eventRow = eventRow
        self.eventRow3 = eventRow3
        self.divider = divider
        self.titleFontPointSize = titleFontPointSize
        self.titleMeasureWidth = titleMeasureWidth
    }

    /// macOS large / iOS large: single wide column (§5.6). Tighter than the defaults to
    /// match the target row density.
    // Values roughly include the spacing that follows each element, so `fillBudget` can be
    // close to the widget's real usable height (widget height − top/bottom contentPadding).
    public static let macOSLarge = RowCost(
        dayHeader: 21, allDayChip: 22, eventRow: 34, eventRow3: 49, divider: 12,
        titleFontPointSize: 13, titleMeasureWidth: 320
    )
    /// iOS medium: the ~65%-width right column (§5.5).
    public static let iOSMedium = RowCost(
        dayHeader: 19, allDayChip: 23, eventRow: 37, eventRow3: 56, divider: 12,
        titleFontPointSize: 15, titleMeasureWidth: 170
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
                nextCursor = Cursor(day: section.day, itemIndex: idx)
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
    return measuredTitleLines(
        item.event.title, pointSize: cost.titleFontPointSize, width: cost.titleMeasureWidth
    ) >= 2 ? cost.eventRow3 : cost.eventRow
}

/// Real line count for `title` at `pointSize`, wrapped to `width` — measures actual text
/// instead of guessing by character count, capped at 2 lines to match `titleLineLimit`
/// (§5.1, §6.3). The title is always bold (`EventRowView`), so this always measures the
/// bold system font regardless of caller.
///
/// The per-line height comes from measuring a real single-line string with the *same*
/// `boundingRect` call, not from `font.ascender - font.descender + font.leading`. That
/// formula is a continuous approximation; `boundingRect` quantizes its result (whole
/// pixels), so a genuine one-line title's height (e.g. 16.0) was consistently ~5% larger
/// than the hand-computed line height (e.g. 15.31 for bold system 13pt) — `/ lineHeight`
/// landed just over 1.0, and `.rounded(.up)` turned every single-line title into "2 lines".
/// Real bug, 2026-09: this made `itemCost` charge `eventRow3` for nearly every row
/// regardless of actual content, which starved `fill` and cut pages well short of the
/// widget's real capacity — the opposite failure mode from the clipping bug this function
/// was written to fix. Measuring the reference line with the identical options keeps
/// numerator and denominator on the same quantization, so a true one-line title measures
/// as 1.
func measuredTitleLines(_ title: String, pointSize: CGFloat, width: CGFloat) -> Int {
    guard width > 0, pointSize > 0 else { return 1 }
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 1 }

    #if canImport(UIKit)
    let font = UIFont.boldSystemFont(ofSize: pointSize)
    #else
    let font = NSFont.boldSystemFont(ofSize: pointSize)
    #endif

    // Not hoisted into a typed local: the options type is spelled `NSString.DrawingOptions`
    // on macOS/AppKit but plain `NSStringDrawingOptions` on iOS/UIKit (no `NS_SWIFT_NAME`
    // there) — no name works as an explicit annotation on both platforms. Repeating the
    // literal lets each `boundingRect` call infer it from context instead, same as before.
    let bounds = (trimmed as NSString).boundingRect(
        with: CGSize(width: width, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
    )
    let lineHeight = ("M" as NSString).boundingRect(
        with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: font],
        context: nil
    ).height
    guard lineHeight > 0 else { return 1 }
    return max(1, min(2, Int((bounds.height / lineHeight).rounded(.up))))
}
