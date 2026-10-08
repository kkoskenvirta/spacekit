import AppKit
import SpaceKitCore
import SwiftUI

/// Colors for the app. Palettes are validated for color-vision deficiency and contrast in both
/// appearances (see docs/DESIGN.md); don't eyeball replacements — re-run the validator.
enum Theme {
    /// A color with separate light and dark steps.
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hex: isDark ? dark : light)
            })
    }

    /// Categorical hues in fixed order: blue, orange, aqua, yellow, magenta, green, violet, red.
    /// Assigned to entities in sequence, never cycled; a 9th entity folds into `other`.
    static let categorical: [Color] = [
        dynamic(light: 0x2a78d6, dark: 0x3987e5),
        dynamic(light: 0xeb6834, dark: 0xd95926),
        dynamic(light: 0x1baf7a, dark: 0x199e70),
        dynamic(light: 0xeda100, dark: 0xc98500),
        dynamic(light: 0xe87ba4, dark: 0xd55181),
        dynamic(light: 0x008300, dark: 0x008300),
        dynamic(light: 0x4a3aa7, dark: 0x9085e9),
        dynamic(light: 0xe34948, dark: 0xe66767),
    ]

    /// Folded / unclassified data.
    static let other = dynamic(light: 0xb5b3ab, dark: 0x5c5b56)

    static func categorical(_ index: Int) -> Color {
        index >= 0 && index < categorical.count ? categorical[index] : other
    }

    // Status — reserved meaning, always shown with an icon and a label.
    static let good = Color(nsColor: NSColor(hex: 0x0ca30c))
    static let warning = Color(nsColor: NSColor(hex: 0xfab219))
    static let critical = Color(nsColor: NSColor(hex: 0xd03b3b))

    static func color(for level: SafetyLevel) -> Color {
        switch level {
        case .safe: return good
        case .review: return warning
        case .protected: return critical
        }
    }

    static func symbol(for level: SafetyLevel) -> String {
        switch level {
        case .safe: return "arrow.triangle.2.circlepath.circle.fill"
        case .review: return "exclamationmark.circle.fill"
        case .protected: return "lock.circle.fill"
        }
    }

    /// Age buckets on a one-hue ordinal ramp: light → dark in light mode, dark → light in dark mode.
    static let ageBuckets: [(label: String, maxDays: Double, color: Color)] = [
        ("This week", 7, dynamic(light: 0x86b6ef, dark: 0x184f95)),
        ("This month", 30, dynamic(light: 0x5598e7, dark: 0x256abf)),
        ("Last 6 months", 182, dynamic(light: 0x2a78d6, dark: 0x3987e5)),
        ("Last year", 365, dynamic(light: 0x1c5cab, dark: 0x6da7ec)),
        ("Older", .infinity, dynamic(light: 0x104281, dark: 0x9ec5f4)),
    ]

    static func ageColor(_ date: Date?) -> Color {
        guard let date else { return other }
        let days = Age.since(date).days
        return (ageBuckets.first { days < $0.maxDays } ?? ageBuckets[ageBuckets.count - 1]).color
    }

    /// Stable color per storage category (identity follows the category, never its rank).
    static func color(for category: StorageCategory) -> Color {
        switch category.id {
        case StorageCategory.developer.id: return categorical[0]
        case StorageCategory.applications.id: return categorical[1]
        case StorageCategory.ai.id: return categorical[2]
        case StorageCategory.documents.id: return categorical[3]
        case StorageCategory.media.id: return categorical[4]
        case StorageCategory.caches.id: return categorical[5]
        case StorageCategory.system.id: return categorical[6]
        case StorageCategory.systemData.id: return categorical[7]
        default: return other
        }
    }

    static let surface = dynamic(light: 0xfcfcfb, dark: 0x1a1a19)
    static let hairline = dynamic(light: 0xe1e0d9, dark: 0x2c2c2a)
    static let mutedInk = Color(nsColor: NSColor(hex: 0x898781))
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}
