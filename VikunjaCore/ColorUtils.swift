import SwiftUI

extension Color {
    /// Parses a Vikunja hex color string (e.g. "ff5733" or "#ff5733") into a Color.
    /// Returns nil when the string is absent or empty.
    init?(vikunjaHex hex: String?) {
        guard let hex, !hex.isEmpty else { return nil }
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6,
              let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8)  & 0xFF) / 255
        let b = Double( value        & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    /// Returns .white or .black (whichever is more legible) over this background color.
    var contrastingForeground: Color {
        // Relative luminance via the W3C formula (linearized sRGB).
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        NSColor(self).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let L = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return L > 0.179 ? .black : .white
    }
}
