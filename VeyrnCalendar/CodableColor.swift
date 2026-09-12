//  Vendored from Calvane Widget — AgendaKit/Sources/AgendaKit/CodableColor.swift @ c2994b2.
//  Calvane is retired; this copy is canonical. See skill/references/calendar.md.

import CoreGraphics

/// An RGBA color that survives `Codable` round-trips.
///
/// `CGColor` is not `Codable`, and the snapshot path (had spike 0 failed) plus test
/// fixtures both need a serializable color. Components are stored in the extended sRGB
/// range and are **not** clamped — a wide-gamut calendar color is preserved as-is.
///
/// Colors come from the owning calendar (`EKCalendar.cgColor`) and nothing else (§5.2);
/// there is no app palette and no per-event override.
public struct CodableColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Best-effort conversion from a `CGColor`. Converts to sRGB when possible; otherwise
    /// falls back to the raw components (grayscale is expanded to RGB). Fully opaque
    /// mid-gray is used only if the color has no usable components at all.
    public init(cgColor: CGColor) {
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
           let c = converted.components, converted.numberOfComponents == 4 {
            self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3]))
            return
        }

        let c = cgColor.components ?? []
        switch c.count {
        case 4:
            self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]), alpha: Double(c[3]))
        case 2:
            self.init(red: Double(c[0]), green: Double(c[0]), blue: Double(c[0]), alpha: Double(c[1]))
        default:
            self.init(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        }
    }

    /// An sRGB `CGColor`. Views build their `SwiftUI.Color` from this (`Color(cgColor:)`)
    /// so `VeyrnCalendar` stays UI-framework-free.
    public var cgColor: CGColor {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGColor(
            colorSpace: space,
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]
        ) ?? CGColor(gray: 0.5, alpha: 1)
    }
}
