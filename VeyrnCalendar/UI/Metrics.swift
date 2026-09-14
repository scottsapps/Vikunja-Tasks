//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/UI/Metrics.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.
//
//  Metrics.swift
//  Widget
//
//  Every hard-coded number from §5 lives here, with per-family values, so tuning against
//  the reference screenshots means editing one file (§5.7). Values are starting points.
//

import SwiftUI

public struct Metrics: Sendable {
    // Outer
    public var contentPadding: EdgeInsets
    public var headerRowToBody: CGFloat        // day header line → first chip/row
    public var emptyDayTopGap: CGFloat         // day header line → "No Events"
    public var emptyDayFont: Font              // "No Events"
    public var interItemSpacing: CGFloat       // between consecutive chips / rows within a day
    public var lineToTitleSpacing: CGFloat     // time/location line → title line, inside a row

    // Calendar dot
    public var dotDiameter: CGFloat
    public var dotBaselineShift: CGFloat       // dot centre, in pt above the first line's text baseline

    // Event row text
    public var timeFont: Font
    public var locationFont: Font
    public var titleFont: Font
    public var titleLineLimit: Int

    // All-day chip (§5.3)
    public var chipCornerRadius: CGFloat
    public var chipPadding: EdgeInsets
    public var chipFont: Font

    // Day header (§5.4)
    public var headerFont: Font               // TODAY / TOMORROW / weekday
    public var dateSuffixFont: Font           // macOS "9/5/26"
    public var headerKerning: CGFloat
    /// iOS medium: header shows only TODAY / TOMORROW (weekday lives in the left column),
    /// no date suffix. macOS large: full "TODAY SATURDAY 9/5/26".
    public var compactHeader: Bool

    // Multi-day section handling (macOS, §5.6)
    public var sectionSpacingAbove: CGFloat   // space above a divider
    public var sectionSpacingBelow: CGFloat   // space below a divider, before next header
    public var showsDividers: Bool
    public var showsDateSuffix: Bool          // macOS yes, iOS no (§5.4)

    // iOS left column (§5.5)
    public var showsLeftColumn: Bool
    public var leftColumnWidthFraction: CGFloat
    public var monthFont: Font
    public var weekdayFont: Font
    public var dayNumberFont: Font
    public var dayNumberBottomTrim: CGFloat   // negative: pull the big digit's baseline down
    public var leftColumnTopGap: CGFloat      // weekday → (spacer) → day number
    public var leftColumnGutter: CGFloat      // gap between the right-aligned left column and the right column

    // Paging chevrons (§7)
    public var chevronFont: Font
    public var chevronSpacing: CGFloat
    public var chevronHitInset: CGFloat

    // Budget for `fill` (§6.3)
    public var fillBudget: CGFloat
    /// Height the provider holds back from the budget when today is empty and an extra
    /// "TODAY / No Events" block is prepended (it isn't part of `fill`'s cost model).
    public var emptyTodayReserve: CGFloat
    /// Cushion subtracted from `fillBudget` before handing it to `fill`. `rowCost` is an
    /// estimate (character-count title-wrap guess, not measured text), so small per-row
    /// errors can add up across a page; this keeps `fill` from cutting it that close, so
    /// the real render lands inside the widget's true height instead of clipping the last
    /// row. Deliberately generic rather than tuned per reference screenshot — it exists to
    /// absorb the *error*, not to hit a pixel target.
    public var fillSafetyMargin: CGFloat
    public var rowCost: RowCost
}

public extension Metrics {
    /// macOS large — single wide column agenda (§5.6).
    static let large = Metrics(
        contentPadding: EdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 16),
        headerRowToBody: 3,
        emptyDayTopGap: 3,
        emptyDayFont: .system(size: 13, weight: .regular),
        interItemSpacing: 6,
        lineToTitleSpacing: 1,
        dotDiameter: 9,
        dotBaselineShift: 4,
        timeFont: .system(size: 12, weight: .semibold),
        locationFont: .system(size: 12, weight: .regular),
        titleFont: .system(size: 13, weight: .bold),
        titleLineLimit: 2,
        chipCornerRadius: 6,
        chipPadding: EdgeInsets(top: 2.5, leading: 8, bottom: 2.5, trailing: 8),
        chipFont: .system(size: 13, weight: .bold),
        headerFont: .system(size: 15, weight: .bold),
        dateSuffixFont: .system(size: 14, weight: .medium),
        headerKerning: 0.3,
        compactHeader: false,
        sectionSpacingAbove: 6,
        sectionSpacingBelow: 5,
        showsDividers: true,
        showsDateSuffix: true,
        showsLeftColumn: false,
        leftColumnWidthFraction: 0,
        monthFont: .system(size: 15, weight: .bold),
        weekdayFont: .system(size: 26, weight: .bold),
        dayNumberFont: .system(size: 76, weight: .regular),
        dayNumberBottomTrim: 0,
        leftColumnTopGap: 0,
        leftColumnGutter: 0,
        chevronFont: .system(size: 12, weight: .semibold),
        chevronSpacing: 10,
        chevronHitInset: 8,
        fillBudget: 314,
        emptyTodayReserve: 44,
        fillSafetyMargin: 12,
        rowCost: .macOSLarge
    )

    /// iOS medium — ~34% / 66% two-column (§5.5). Left column is right-aligned.
    static let medium = Metrics(
        contentPadding: EdgeInsets(top: 17, leading: 19, bottom: 14, trailing: 16),
        headerRowToBody: 5,
        emptyDayTopGap: 1,
        emptyDayFont: .system(size: 12, weight: .regular),
        interItemSpacing: 7,
        lineToTitleSpacing: 1,
        dotDiameter: 9,
        dotBaselineShift: 4,
        timeFont: .system(size: 13, weight: .semibold),
        locationFont: .system(size: 13, weight: .regular),
        titleFont: .system(size: 15, weight: .bold),
        titleLineLimit: 2,
        chipCornerRadius: 6,
        chipPadding: EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8),
        chipFont: .system(size: 14, weight: .bold),
        headerFont: .system(size: 15, weight: .bold),
        dateSuffixFont: .system(size: 14, weight: .semibold),
        headerKerning: 0.3,
        compactHeader: true,
        sectionSpacingAbove: 8,
        sectionSpacingBelow: 6,
        showsDividers: false,
        showsDateSuffix: false,
        showsLeftColumn: true,
        leftColumnWidthFraction: 0.34,
        monthFont: .system(size: 13, weight: .bold),
        weekdayFont: .system(size: 19, weight: .bold),
        dayNumberFont: .system(size: 74, weight: .regular),
        dayNumberBottomTrim: -4,
        leftColumnTopGap: 0,
        leftColumnGutter: 14,
        chevronFont: .system(size: 12, weight: .semibold),
        chevronSpacing: 10,
        chevronHitInset: 8,
        fillBudget: 146,
        emptyTodayReserve: 42,
        fillSafetyMargin: 12,
        rowCost: .iOSMedium
    )

    static func forFamily(_ family: AgendaFamily) -> Metrics {
        switch family {
        case .large: return .large
        case .medium: return .medium
        }
    }
}
