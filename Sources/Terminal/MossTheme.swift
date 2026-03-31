import SwiftUI
import GhosttyKit

/// Theme colors derived from ghostty config, used across all Moss UI.
@MainActor
@Observable
final class MossTheme {
    let background: Color
    let foreground: Color
    let backgroundOpacity: Double
    /// Overlay opacity derived from ghostty's unfocused-split-opacity.
    let unfocusedSplitOpacity: Double
    /// Fill color derived from ghostty's unfocused-split-fill, or background.
    let unfocusedSplitFill: Color

    /// Slightly lighter/darker variant for panel surfaces
    let surfaceBackground: Color
    /// Subtle border/divider color
    let border: Color
    /// Dimmed foreground for secondary text
    let secondaryForeground: Color
    /// ANSI palette colors 0-15 from ghostty config
    let paletteColors: [NSColor]
    /// Whether the theme is dark (based on background luminance)
    let isDark: Bool

    // MARK: - Surface hierarchy (each level lifts further from surfaceBackground)

    /// Panel headers, editor canvas, code preview background
    let elevatedBackground: Color
    /// Close button bg, empty state fill
    let raisedBackground: Color
    /// Header icon bg, prominent surface elements
    let prominentBackground: Color

    // MARK: - Interactive states

    /// Row hover highlight (semi-transparent surface)
    let hoverBackground: Color
    /// Rest-state accent tint for toolbar buttons
    let accentSubtle: Color
    /// Hover-state accent tint for toolbar/dropdown
    let accentHover: Color

    // MARK: - Border hierarchy

    /// Input field borders, subtle outlines
    let borderSubtle: Color
    /// Toolbar button borders, separators
    let borderMedium: Color
    /// Divider overlays, active button borders
    let borderStrong: Color

    // MARK: - Git status

    let gitModified: Color
    let gitAdded: Color
    let gitDeleted: Color
    let gitRenamed: Color

    // MARK: - Diff (NSColor for AppKit views)

    let diffAdded: NSColor
    let diffRemoved: NSColor
    let diffHunk: NSColor

    // MARK: - Scroller (NSColor for AppKit)

    let scrollerThumb: NSColor
    let scrollerThumbHover: NSColor
    let scrollerThumbActive: NSColor

    // MARK: - Agent status

    let agentRunning: Color
    let agentWaiting: Color
    let agentIdle: Color
    let agentError: Color

    func color(for status: AgentStatus) -> Color {
        switch status {
        case .running: return agentRunning
        case .waiting: return agentWaiting
        case .idle:    return agentIdle
        case .error:   return agentError
        case .none:    return .clear
        }
    }

    /// Access a palette color by ANSI index (0-15).
    func palette(_ index: Int) -> NSColor {
        guard index >= 0, index < paletteColors.count else {
            return NSColor.labelColor
        }
        return paletteColors[index]
    }

    init(config: ghostty_config_t?) {
        var bg = ghostty_config_color_s(r: 0, g: 0, b: 0)
        var fg = ghostty_config_color_s(r: 255, g: 255, b: 255)
        var opacity: Double = 1.0
        var unfocusedSplitOpacityValue: Double = 0.85
        var unfocusedSplitFillValue = bg
        var palette = ghostty_config_palette_s()

        if let config {
            let bgKey = "background"
            let fgKey = "foreground"
            let opKey = "background-opacity"
            let unfocusedSplitOpacityKey = "unfocused-split-opacity"
            let unfocusedSplitFillKey = "unfocused-split-fill"
            let paletteKey = "palette"
            ghostty_config_get(config, &bg, bgKey, UInt(bgKey.utf8.count))
            ghostty_config_get(config, &fg, fgKey, UInt(fgKey.utf8.count))
            ghostty_config_get(config, &opacity, opKey, UInt(opKey.utf8.count))
            ghostty_config_get(config, &palette, paletteKey, UInt(paletteKey.utf8.count))
            ghostty_config_get(
                config,
                &unfocusedSplitOpacityValue,
                unfocusedSplitOpacityKey,
                UInt(unfocusedSplitOpacityKey.utf8.count)
            )
            if !ghostty_config_get(
                config,
                &unfocusedSplitFillValue,
                unfocusedSplitFillKey,
                UInt(unfocusedSplitFillKey.utf8.count)
            ) {
                unfocusedSplitFillValue = bg
            }
        }

        self.paletteColors = withUnsafeBytes(of: palette.colors) { buf in
            let colors = buf.bindMemory(to: ghostty_config_color_s.self)
            return (0..<16).map { i in
                let c = colors[i]
                return NSColor(
                    red: CGFloat(c.r) / 255,
                    green: CGFloat(c.g) / 255,
                    blue: CGFloat(c.b) / 255,
                    alpha: 1
                )
            }
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
        self.unfocusedSplitOpacity = 1 - unfocusedSplitOpacityValue
        self.unfocusedSplitFill = Color(
            red: Double(unfocusedSplitFillValue.r) / 255,
            green: Double(unfocusedSplitFillValue.g) / 255,
            blue: Double(unfocusedSplitFillValue.b) / 255
        )

        // Determine if theme is light or dark based on bg luminance
        let luminance = (0.299 * Double(bg.r) + 0.587 * Double(bg.g) + 0.114 * Double(bg.b)) / 255
        let isLight = luminance > 0.5
        self.isDark = !isLight

        NSLog("[MossTheme] bg=(%d,%d,%d) luminance=%.3f isDark=%d", bg.r, bg.g, bg.b, luminance, !isLight)

        // Surface is a subtle shift from background
        self.surfaceBackground = isLight
            ? bgColor.mix(with: .black, by: 0.04)
            : bgColor.mix(with: .white, by: 0.04)

        self.border = isLight
            ? bgColor.mix(with: .black, by: 0.12)
            : bgColor.mix(with: .white, by: 0.10)

        self.secondaryForeground = fgColor.opacity(0.6)

        // Surface hierarchy
        self.elevatedBackground = surfaceBackground.mix(with: .white, by: 0.02)
        self.raisedBackground = surfaceBackground.mix(with: .white, by: 0.04)
        self.prominentBackground = surfaceBackground.mix(with: .white, by: 0.08)

        // Interactive states
        self.hoverBackground = surfaceBackground.opacity(0.72)
        self.accentSubtle = surfaceBackground.mix(with: .accentColor, by: 0.02)
        self.accentHover = surfaceBackground.mix(with: .accentColor, by: 0.10)

        // Border hierarchy
        self.borderSubtle = border.opacity(0.5)
        self.borderMedium = border.opacity(0.65)
        self.borderStrong = border.opacity(0.9)

        // Git status
        self.gitModified = Color(nsColor: .systemOrange)
        self.gitAdded = Color(nsColor: .systemGreen)
        self.gitDeleted = Color(nsColor: .systemRed)
        self.gitRenamed = Color(nsColor: .systemBlue)

        // Diff colors — brighter tints for light mode, deeper for dark
        if isLight {
            self.diffAdded = NSColor(srgbRed: 0.30, green: 0.75, blue: 0.38, alpha: 1)
            self.diffRemoved = NSColor(srgbRed: 0.82, green: 0.28, blue: 0.25, alpha: 1)
            self.diffHunk = NSColor(srgbRed: 0.38, green: 0.65, blue: 0.92, alpha: 1)
        } else {
            self.diffAdded = NSColor(srgbRed: 0.10, green: 0.38, blue: 0.18, alpha: 1)
            self.diffRemoved = NSColor(srgbRed: 0.45, green: 0.12, blue: 0.12, alpha: 1)
            self.diffHunk = NSColor(srgbRed: 0.34, green: 0.67, blue: 0.92, alpha: 1)
        }

        // Scroller
        let scrollerBase: NSColor = isLight
            ? NSColor(srgbRed: 17 / 255, green: 24 / 255, blue: 39 / 255, alpha: 1)
            : .white
        self.scrollerThumb = scrollerBase.withAlphaComponent(0.16)
        self.scrollerThumbHover = scrollerBase.withAlphaComponent(0.24)
        self.scrollerThumbActive = scrollerBase.withAlphaComponent(0.32)

        // Agent status
        self.agentRunning = Color(nsColor: .systemBlue)
        self.agentWaiting = Color(nsColor: .systemOrange)
        self.agentIdle = Color(nsColor: .systemGreen)
        self.agentError = Color(nsColor: .systemRed)
    }

    /// Fallback theme for when no ghostty config is available.
    static let fallback = MossTheme(config: nil)
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
    static let defaultValue: MossTheme = .fallback
}

extension EnvironmentValues {
    var mossTheme: MossTheme {
        get { self[MossThemeKey.self] }
        set { self[MossThemeKey.self] = newValue }
    }
}
