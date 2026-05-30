import Foundation

enum DictationNormalizer {
    /// Glue dictated symbols to the following token so QuickAddParser can match them.
    /// "buy milk * groceries ! 1" -> "buy milk *groceries !1"
    static func normalize(_ raw: String) -> String {
        var s = raw
        for sym in ["*", "+"] {
            s = s.replacingOccurrences(
                of: "\\\(sym)\\s+(?=\\w)", with: sym,
                options: .regularExpression)
        }
        s = s.replacingOccurrences(
            of: "!\\s+(?=[1-5]\\b)", with: "!",
            options: .regularExpression)
        return s
    }
}
