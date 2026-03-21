import SwiftUI
import GhosttyKit

/// Theme colors derived from ghostty config, used across all Moss UI.
@MainActor
@Observable
final class MossTheme {
    let background: Color
    let foreground: Color
    let backgroundOpacity: Double

    /// Slightly lighter/darker variant for panel surfaces
    let surfaceBackground: Color
    /// Subtle border/divider color
    let border: Color
    /// Dimmed foreground for secondary text
    let secondaryForeground: Color

    init(config: ghostty_config_t?) {
        var bg = ghostty_config_color_s(r: 0, g: 0, b: 0)
        var fg = ghostty_config_color_s(r: 255, g: 255, b: 255)
        var opacity: Double = 1.0

        if let config {
            let bgKey = "background"
            let fgKey = "foreground"
            let opKey = "background-opacity"
            ghostty_config_get(config, &bg, bgKey, UInt(bgKey.utf8.count))
            ghostty_config_get(config, &fg, fgKey, UInt(fgKey.utf8.count))
            ghostty_config_get(config, &opacity, opKey, UInt(opKey.utf8.count))
        }

        let bgColor = Color(
            red: Double(bg.r) / 255,
            green: Double(bg.g) / 255,
            blue: Double(bg.b) / 255
        )
        let fgColor = Color(
            red: Double(fg.r) / 255,
            green: Double(fg.g) / 255,
            blue: Double(fg.b) / 255
        )

        self.background = bgColor
        self.foreground = fgColor
        self.backgroundOpacity = opacity

        // Determine if theme is light or dark based on bg luminance
        let luminance = (0.299 * Double(bg.r) + 0.587 * Double(bg.g) + 0.114 * Double(bg.b)) / 255
        let isLight = luminance > 0.5

        // Surface is a subtle shift from background
        self.surfaceBackground = isLight
            ? bgColor.mix(with: .black, by: 0.04)
            : bgColor.mix(with: .white, by: 0.04)

        self.border = isLight
            ? bgColor.mix(with: .black, by: 0.12)
            : bgColor.mix(with: .white, by: 0.10)

        self.secondaryForeground = fgColor.opacity(0.6)
    }
}

// MARK: - Color mixing helper

extension Color {
    func mix(with other: Color, by fraction: Double) -> Color {
        // Resolve via NSColor for reliable component access
        let base = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        let blend = NSColor(other).usingColorSpace(.sRGB) ?? NSColor(other)
        let f = CGFloat(fraction)
        return Color(
            red: Double(base.redComponent * (1 - f) + blend.redComponent * f),
            green: Double(base.greenComponent * (1 - f) + blend.greenComponent * f),
            blue: Double(base.blueComponent * (1 - f) + blend.blueComponent * f)
        )
    }
}

// MARK: - Environment key

private struct MossThemeKey: EnvironmentKey {
    static let defaultValue: MossTheme? = nil
}

extension EnvironmentValues {
    var mossTheme: MossTheme? {
        get { self[MossThemeKey.self] }
        set { self[MossThemeKey.self] = newValue }
    }
}
