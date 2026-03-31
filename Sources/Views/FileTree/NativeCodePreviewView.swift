import AppKit
import OSLog
import SwiftTreeSitter
import SwiftTreeSitterLayer
import SwiftUI

private let nativePreviewLogger = Logger(subsystem: "dev.moss.app", category: "NativeCodePreview")

struct NativeCodePreviewView: NSViewRepresentable {
    let text: String
    let fileURL: URL
    let theme: MossTheme
    var wrapLines: Bool = false

    func makeNSView(context: Context) -> CodePreviewScrollView {
        let wrapper = CodePreviewScrollView()
        wrapper.applyContent(text: text, fileURL: fileURL, theme: theme, wrapLines: wrapLines)
        return wrapper
    }

    func updateNSView(_ wrapper: CodePreviewScrollView, context: Context) {
        wrapper.applyContent(text: text, fileURL: fileURL, theme: theme, wrapLines: wrapLines)
    }
}

// MARK: - Scroll View Wrapper

@MainActor
final class CodePreviewScrollView: NSView {
    private let scrollView: NSScrollView
    private let textView: NSTextView
    private let rulerView: LineNumberRulerView

    private var currentFileURL: URL?
    private var currentTheme: MossTheme?
    private var currentWrapLines: Bool = false
    private var appliedText: String?
    private static var scrollCache: [String: CGPoint] = [:]

    override init(frame frameRect: NSRect) {
        let sv = NSTextView.scrollableTextView()
        scrollView = sv
        textView = sv.documentView as! NSTextView
        rulerView = LineNumberRulerView(textView: textView)

        super.init(frame: frameRect)

        // Text view config
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)

        // Non-wrapping (default — toggled via applyWrapMode)
        applyWrapMode(false)
        if textView.textLayoutManager == nil {
            textView.layoutManager?.allowsNonContiguousLayout = true
        }

        // Scroll view config
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.horizontalScroller = ThemedOverlayScroller()
        scrollView.verticalScroller = ThemedOverlayScroller()

        // Line numbers
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = rulerView
        scrollView.rulersVisible = true

        // Redraw ruler on scroll
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            rulerView,
            selector: #selector(LineNumberRulerView.handleScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func applyContent(text: String, fileURL: URL, theme: MossTheme, wrapLines: Bool) {
        let themeChanged = !isSameTheme(theme)
        let fileChanged = currentFileURL != fileURL
        let textChanged = appliedText != text
        let wrapChanged = currentWrapLines != wrapLines

        guard textChanged || fileChanged || themeChanged || wrapChanged else { return }

        // Save scroll position for old file
        if let oldURL = currentFileURL, fileChanged {
            Self.scrollCache[oldURL.path] = scrollView.contentView.bounds.origin
        }

        currentFileURL = fileURL
        currentTheme = theme
        currentWrapLines = wrapLines
        appliedText = text

        // Apply wrap mode
        if wrapChanged || fileChanged {
            applyWrapMode(wrapLines)
        }

        // Theme colors
        let bgColor = NSColor(theme.elevatedBackground)
        let raw = NSColor(Color(theme.foreground))
        let fgColor = raw.usingColorSpace(.sRGB) ?? raw
        textView.backgroundColor = bgColor
        rulerView.backgroundColor = bgColor
        rulerView.textColor = NSColor(Color(theme.secondaryForeground)).withAlphaComponent(0.6)
        (scrollView.horizontalScroller as? ThemedOverlayScroller)?.applyTheme(theme)
        (scrollView.verticalScroller as? ThemedOverlayScroller)?.applyTheme(theme)

        // Build attributed string with syntax highlighting
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let languageConfig = TreeSitterLanguageProvider.configuration(for: fileURL)
        let attributedString = highlightedString(
            text: text,
            languageConfig: languageConfig,
            theme: theme,
            font: font,
            defaultColor: fgColor
        )
        textView.textStorage?.setAttributedString(attributedString)
        rulerView.needsDisplay = true

        // Restore scroll position
        if fileChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let saved = Self.scrollCache[fileURL.path] {
                    self.scrollView.contentView.scroll(to: saved)
                } else {
                    self.textView.scrollToBeginningOfDocument(nil)
                }
                self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
            }
        }
    }

    // MARK: - Tree-sitter Highlighting

    private func highlightedString(
        text: String,
        languageConfig: LanguageConfiguration?,
        theme: MossTheme,
        font: NSFont,
        defaultColor: NSColor
    ) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: defaultColor,
        ]

        guard let languageConfig else {
            return NSAttributedString(string: text, attributes: baseAttrs)
        }

        let attributed = NSMutableAttributedString(string: text, attributes: baseAttrs)
        let colorMap = buildColorMap(theme: theme, font: font, defaultColor: defaultColor)

        do {
            let language = languageConfig.language
            let parser = Parser()
            try parser.setLanguage(language)

            guard let tree = parser.parse(text) else {
                return attributed
            }

            guard let highlightQuery = languageConfig.queries[.highlights] else {
                return attributed
            }

            let cursor = highlightQuery.execute(in: tree)

            while let match = cursor.next() {
                for capture in match.captures {
                    guard let captureName = highlightQuery.captureName(for: capture.index) else { continue }
                    let range = capture.range
                    guard range.location != NSNotFound,
                          range.length > 0,
                          NSMaxRange(range) <= (text as NSString).length
                    else { continue }

                    if let attrs = resolveAttributes(captureName: captureName, colorMap: colorMap) {
                        attributed.addAttributes(attrs, range: range)
                    }
                }
            }
        } catch {
            nativePreviewLogger.error("Tree-sitter highlighting failed: \(error.localizedDescription, privacy: .public)")
        }

        return attributed
    }

    private struct ColorMap {
        let font: NSFont
        let boldFont: NSFont
        let italicFont: NSFont
        let foreground: NSColor
        let dimmed: NSColor
        let red: NSColor
        let green: NSColor
        let yellow: NSColor
        let blue: NSColor
        let magenta: NSColor
        let cyan: NSColor
        let brightRed: NSColor
        let brightCyan: NSColor
    }

    private func buildColorMap(theme: MossTheme, font: NSFont, defaultColor: NSColor) -> ColorMap {
        let boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)

        return ColorMap(
            font: font,
            boldFont: boldFont,
            italicFont: italicFont,
            foreground: defaultColor,
            dimmed: defaultColor.withAlphaComponent(0.5),
            red: theme.palette(1),
            green: theme.palette(2),
            yellow: theme.palette(3),
            blue: theme.palette(4),
            magenta: theme.palette(5),
            cyan: theme.palette(6),
            brightRed: theme.palette(9),
            brightCyan: theme.palette(14)
        )
    }

    private func resolveAttributes(captureName: String, colorMap: ColorMap) -> [NSAttributedString.Key: Any]? {
        if captureName.hasPrefix("keyword") {
            return [.foregroundColor: colorMap.magenta, .font: colorMap.boldFont]
        }

        switch captureName {
        case "string", "string.special":
            return [.foregroundColor: colorMap.green, .font: colorMap.font]
        case "comment", "spell":
            return [.foregroundColor: colorMap.dimmed, .font: colorMap.italicFont]
        case "number", "float", "number.float":
            return [.foregroundColor: colorMap.yellow, .font: colorMap.font]
        case "type", "type.builtin", "type.definition", "constructor":
            return [.foregroundColor: colorMap.cyan, .font: colorMap.font]
        case "function", "function.call", "function.builtin", "function.method", "method":
            return [.foregroundColor: colorMap.blue, .font: colorMap.font]
        case "variable", "variable.builtin", "variable.parameter", "parameter":
            return [.foregroundColor: colorMap.foreground, .font: colorMap.font]
        case "constant", "constant.builtin", "boolean":
            return [.foregroundColor: colorMap.brightRed, .font: colorMap.font]
        case "property", "property.definition", "field":
            return [.foregroundColor: colorMap.brightCyan, .font: colorMap.font]
        case "operator":
            return [.foregroundColor: colorMap.red, .font: colorMap.font]
        case "punctuation", "punctuation.bracket", "punctuation.delimiter", "punctuation.special":
            return nil
        case "tag", "tag.builtin":
            return [.foregroundColor: colorMap.red, .font: colorMap.font]
        case "attribute", "attribute.builtin":
            return [.foregroundColor: colorMap.yellow, .font: colorMap.font]
        case "namespace", "module":
            return [.foregroundColor: colorMap.cyan, .font: colorMap.font]
        case "label":
            return [.foregroundColor: colorMap.magenta, .font: colorMap.font]
        case "escape", "string.escape":
            return [.foregroundColor: colorMap.brightRed, .font: colorMap.font]
        default:
            return nil
        }
    }

    private func applyWrapMode(_ wrap: Bool) {
        let contentWidth = max(scrollView.contentSize.width, 100)
        let inset = textView.textContainerInset.width

        if wrap {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.frame.size.width = contentWidth
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(
                width: contentWidth - inset * 2,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.maxSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.textContainer?.heightTracksTextView = false

        scrollView.hasHorizontalScroller = !wrap

        // Force layout recalculation
        textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: 0))
        textView.needsLayout = true
        textView.needsDisplay = true
        rulerView.needsDisplay = true
    }

    private func isSameTheme(_ other: MossTheme) -> Bool {
        guard let a = currentTheme else { return false }
        return a === other
    }
}

// MARK: - Line Number Ruler

final class LineNumberRulerView: NSRulerView {
    var textColor: NSColor = .secondaryLabelColor
    var backgroundColor: NSColor = .textBackgroundColor

    private let lineNumberFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView) {
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        // Clip to ruler width to prevent painting over the text area
        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: ruleThickness, height: bounds.height)).addClip()

        backgroundColor.setFill()
        rect.fill()

        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(
            forBoundingRect: visibleRect,
            in: textContainer
        )
        let visibleCharRange = layoutManager.characterRange(
            forGlyphRange: visibleGlyphRange,
            actualGlyphRange: nil
        )

        let content = textView.string as NSString
        let containerOrigin = textView.textContainerOrigin
        let attrs: [NSAttributedString.Key: Any] = [
            .font: lineNumberFont,
            .foregroundColor: textColor,
        ]

        var lineNumber = 1

        // Count lines before visible range
        content.enumerateSubstrings(
            in: NSRange(location: 0, length: visibleCharRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in
            lineNumber += 1
        }

        // Draw visible line numbers
        content.enumerateSubstrings(
            in: visibleCharRange,
            options: [.byLines, .substringNotRequired]
        ) { _, substringRange, _, _ in
            let glyphRange = layoutManager.glyphRange(forCharacterRange: substringRange, actualCharacterRange: nil)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            // Adjust for text container inset and scroll position
            lineRect.origin.y += containerOrigin.y
            lineRect.origin.y -= visibleRect.origin.y

            let lineStr = "\(lineNumber)" as NSString
            let size = lineStr.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: self.ruleThickness - size.width - 6,
                y: lineRect.origin.y + (lineRect.height - size.height) / 2
            )
            lineStr.draw(at: drawPoint, withAttributes: attrs)
            lineNumber += 1
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    @objc func handleScroll(_ notification: Notification) {
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
}
