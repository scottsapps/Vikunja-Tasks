import Foundation
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformFont = UIFont
#endif

enum RichTextUtils {
    /// Body size the note editor uses; HTML imports are normalized to it.
    static let baseFontSize: CGFloat = 13

    // Must be called on the main thread — Foundation's HTML parser uses WebKit internally.
    static func attributedString(from html: String) -> NSAttributedString {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            return NSAttributedString()
        }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let parsed = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) else {
            return NSAttributedString(string: html)
        }
        // Strip foreground color baked in by the HTML parser so the text view's
        // adaptive label color applies correctly in dark mode.
        let mutable = NSMutableAttributedString(attributedString: parsed)
        mutable.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: mutable.length))
        normalizeFonts(in: mutable)
        return mutable
    }

    /// The HTML parser falls back to Times New Roman for markup that carries no
    /// font-family — which is most of it, since Vikunja's own web editor writes
    /// plain `<p>` tags. Remap every run onto the UI font, keeping bold/italic/
    /// monospace and the relative sizing that makes headings bigger than body text.
    private static func normalizeFonts(in text: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: text.length)
        guard text.length > 0 else { return }

        // Take the size covering the most characters as the document's body size,
        // so notes already written at our own size round-trip unchanged.
        var coverage: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let size = (value as? PlatformFont)?.pointSize ?? baseFontSize
            coverage[size, default: 0] += range.length
        }
        let sourceBase = coverage.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key ?? baseFontSize
        guard sourceBase > 0 else { return }

        text.beginEditing()
        text.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let font = (value as? PlatformFont) ?? PlatformFont.systemFont(ofSize: baseFontSize)
            // Code runs come out of the parser slightly larger than body text; keep
            // them at body size rather than letting them snap up a step.
            let scaled = isMonospaced(font)
                ? baseFontSize
                : baseFontSize * snappedRatio(font.pointSize / sourceBase)
            text.addAttribute(.font, value: uiFont(matching: font, size: scaled), range: range)
        }
        text.endEditing()
    }

    /// Sizes are snapped to these multiples of the body size. Our HTML export keeps
    /// absolute pixel sizes on headings but loses them on body text, so scaling
    /// headings freely would grow them a little on every open-and-save round trip.
    private static let sizeRatios: [CGFloat] = [0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0]

    private static func snappedRatio(_ ratio: CGFloat) -> CGFloat {
        var best = sizeRatios[0]
        // Strict `<` keeps the smaller candidate on a tie, so snapping is stable.
        for candidate in sizeRatios where abs(candidate - ratio) < abs(best - ratio) {
            best = candidate
        }
        return best
    }

    private static func isMonospaced(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        return font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        #else
        return font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        #endif
    }

    private static func isBold(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        return font.fontDescriptor.symbolicTraits.contains(.bold)
        #else
        return font.fontDescriptor.symbolicTraits.contains(.traitBold)
        #endif
    }

    private static func isItalic(_ font: PlatformFont) -> Bool {
        #if os(macOS)
        return font.fontDescriptor.symbolicTraits.contains(.italic)
        #else
        return font.fontDescriptor.symbolicTraits.contains(.traitItalic)
        #endif
    }

    private static func uiFont(matching font: PlatformFont, size: CGFloat) -> PlatformFont {
        let traits = font.fontDescriptor.symbolicTraits
        #if os(macOS)
        let isBold = traits.contains(.bold)
        let isItalic = traits.contains(.italic)
        let isMono = traits.contains(.monoSpace)
        let weight: NSFont.Weight = isBold ? .bold : .regular
        let base = isMono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return isItalic ? NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask) : base
        #else
        let isBold = traits.contains(.traitBold)
        let isItalic = traits.contains(.traitItalic)
        let isMono = traits.contains(.traitMonoSpace)
        let weight: UIFont.Weight = isBold ? .bold : .regular
        let base = isMono
            ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        guard isItalic,
              let desc = base.fontDescriptor.withSymbolicTraits(
                  base.fontDescriptor.symbolicTraits.union(.traitItalic)) else { return base }
        return UIFont(descriptor: desc, size: size)
        #endif
    }

    /// Serializes to the same semantic tags Vikunja's own editor uses.
    ///
    /// Cocoa's HTML writer is not usable here: it describes monospace, underline and
    /// strikethrough in a `<head>` stylesheet and only puts `class` references in the
    /// body, so keeping the body alone (all Vikunja stores) silently dropped those
    /// three. Writing the tags directly also stops us handing the server markup full
    /// of `Helvetica Neue` and dangling class names.
    static func html(from attrStr: NSAttributedString) -> String {
        guard attrStr.length > 0 else { return "" }
        let ns = attrStr.string as NSString
        var out: [String] = []
        // One entry per open list level, outermost first.
        var listTags: [String] = []
        var itemOpen: [Bool] = []

        func appendToLast(_ markup: String) {
            if out.isEmpty { out.append(markup) } else { out[out.count - 1] += markup }
        }
        func closeInnermostList() {
            if itemOpen.last == true { appendToLast("</li>") }
            let tag = listTags.removeLast()
            itemOpen.removeLast()
            out.append("</\(tag)>")
            // A nested list sits inside its parent's item, which now ends too.
            if !itemOpen.isEmpty {
                appendToLast("</li>")
                itemOpen[itemOpen.count - 1] = false
            }
        }
        func closeAllLists() { while !listTags.isEmpty { closeInnermostList() } }

        var location = 0
        while location < ns.length {
            let paraRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paraRange)

            var contentRange = paraRange
            while contentRange.length > 0,
                  let last = ns.substring(
                      with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)
                  ).unicodeScalars.first,
                  CharacterSet.newlines.contains(last) {
                contentRange.length -= 1
            }

            let style = contentRange.length > 0
                ? attrStr.attribute(.paragraphStyle, at: contentRange.location,
                                    effectiveRange: nil) as? NSParagraphStyle
                : nil
            let lists = style?.textLists ?? []

            if lists.isEmpty {
                closeAllLists()
                let tag = headingTag(attrStr, in: contentRange)
                let inner = inlineHTML(attrStr, in: contentRange, insideHeading: tag != "p")
                out.append("<\(tag)>\(inner)</\(tag)>")
                continue
            }

            // List markers ("\t•\t") live in the text itself; they belong to the tag.
            contentRange = strippingListMarker(ns, in: contentRange)
            let depth = lists.count
            let wantTag = isOrdered(lists[depth - 1].markerFormat) ? "ol" : "ul"
            while listTags.count > depth { closeInnermostList() }
            if listTags.count == depth, listTags[depth - 1] != wantTag { closeInnermostList() }
            while listTags.count < depth {
                let tag = isOrdered(lists[listTags.count].markerFormat) ? "ol" : "ul"
                out.append("<\(tag)>")
                listTags.append(tag)
                itemOpen.append(false)
            }
            if itemOpen[depth - 1] { appendToLast("</li>") }
            out.append("<li>\(inlineHTML(attrStr, in: contentRange, insideHeading: false))")
            itemOpen[depth - 1] = true
        }
        closeAllLists()
        return out.joined(separator: "\n")
    }

    private static func isOrdered(_ marker: NSTextList.MarkerFormat) -> Bool {
        switch marker {
        case .disc, .circle, .square, .hyphen, .box, .check, .diamond: return false
        default: return true
        }
    }

    private static func strippingListMarker(_ ns: NSString, in range: NSRange) -> NSRange {
        let raw = ns.substring(with: range) as NSString
        guard raw.hasPrefix("\t") else { return range }
        let rest = NSRange(location: 1, length: raw.length - 1)
        let secondTab = raw.range(of: "\t", options: [], range: rest)
        guard secondTab.location != NSNotFound else { return range }
        let skip = NSMaxRange(secondTab)
        return NSRange(location: range.location + skip, length: range.length - skip)
    }

    /// A paragraph is a heading if it is set larger than body text. `normalizeFonts`
    /// has already snapped sizes to `sizeRatios`, so these thresholds land on the
    /// same tag every time and headings survive repeated open-and-save cycles.
    private static func headingTag(_ text: NSAttributedString, in range: NSRange) -> String {
        guard range.length > 0 else { return "p" }
        var largest: CGFloat = 0
        text.enumerateAttribute(.font, in: range, options: []) { value, _, _ in
            largest = max(largest, (value as? PlatformFont)?.pointSize ?? baseFontSize)
        }
        let ratio = largest / baseFontSize
        if ratio >= 1.75 { return "h1" }
        if ratio >= 1.4 { return "h2" }
        if ratio >= 1.1 { return "h3" }
        return "p"
    }

    private static func inlineHTML(_ text: NSAttributedString, in range: NSRange,
                                   insideHeading: Bool) -> String {
        guard range.length > 0 else { return "" }
        var result = ""
        text.enumerateAttributes(in: range, options: []) { attrs, runRange, _ in
            // Images arrive as attachments with no recoverable source; see the
            // known-gaps note in the skill.
            guard attrs[.attachment] == nil else { return }
            let piece = escape((text.string as NSString).substring(with: runRange))
            guard !piece.isEmpty else { return }

            var open = "", close = ""
            func wrap(_ tag: String) {
                open += "<\(tag)>"
                close = "</\(tag)>" + close
            }
            let link = linkURL(attrs[.link])
            if let font = attrs[.font] as? PlatformFont {
                if isMonospaced(font) { wrap("code") }
                // Heading tags carry their own weight; nesting <strong> inside one
                // would re-import as bold-on-bold.
                if isBold(font) && !insideHeading { wrap("strong") }
                if isItalic(font) { wrap("em") }
            }
            // Links are underlined by the parser on the way in, so writing <u> here
            // would accumulate markup the user never asked for.
            if link == nil, let value = attrs[.underlineStyle] as? Int, value != 0 { wrap("u") }
            if let value = attrs[.strikethroughStyle] as? Int, value != 0 { wrap("s") }

            let body = open + piece + close
            result += link.map { "<a href=\"\(escapeAttribute($0))\">\(body)</a>" } ?? body
        }
        return result
    }

    private static func linkURL(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            // A line break inside a paragraph, and the placeholder left by a
            // dropped attachment.
            .replacingOccurrences(of: "\u{2028}", with: "<br>")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
