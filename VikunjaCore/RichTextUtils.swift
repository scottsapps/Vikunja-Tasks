import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum RichTextUtils {
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
        return (try? NSAttributedString(data: data, options: opts, documentAttributes: nil))
            ?? NSAttributedString(string: html)
    }

    static func html(from attrStr: NSAttributedString) -> String {
        guard attrStr.length > 0 else { return "" }
        let range = NSRange(location: 0, length: attrStr.length)
        let opts: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let data = try? attrStr.data(from: range, documentAttributes: opts),
              let fullHTML = String(data: data, encoding: .utf8) else {
            return attrStr.string
        }
        return extractBody(from: fullHTML)
    }

    private static func extractBody(from html: String) -> String {
        guard let start = html.range(of: "<body>"),
              let end = html.range(of: "</body>") else { return html }
        return String(html[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
