import AppKit
import SwiftUI

struct FileDiffSummary: Equatable {
    let additions: Int
    let deletions: Int

    var totalChanges: Int { additions + deletions }
}

enum FileDiffError: LocalizedError {
    case notInGitRepository
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInGitRepository:
            return "Not in a git repository"
        case let .commandFailed(message):
            return message
        }
    }
}

enum FileDiffLoader {
    private enum GitFileState {
        case tracked
        case untracked
    }

    static func loadSummary(
        for url: URL,
        completion: @escaping (Result<FileDiffSummary, FileDiffError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = loadSummarySync(for: url)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    static func loadDiff(
        for url: URL,
        completion: @escaping (Result<String, FileDiffError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = loadDiffSync(for: url)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private static func loadSummarySync(for url: URL) -> Result<FileDiffSummary, FileDiffError> {
        switch fileState(for: url) {
        case .success(.tracked):
            return loadSummary(
                arguments: ["diff", "--numstat", "HEAD", "--", url.lastPathComponent],
                in: url
            )
        case .success(.untracked):
            return loadSummary(
                arguments: ["diff", "--no-index", "--numstat", "/dev/null", url.lastPathComponent],
                in: url,
                successStatuses: [0, 1]
            )
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func loadSummary(
        arguments: [String],
        in url: URL,
        successStatuses: Set<Int> = [0]
    ) -> Result<FileDiffSummary, FileDiffError> {
        switch runGit(arguments: arguments, in: url, successStatuses: successStatuses) {
        case let .success(output):
            return .success(parseSummary(from: output))
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func loadDiffSync(for url: URL) -> Result<String, FileDiffError> {
        switch fileState(for: url) {
        case .success(.tracked):
            return runGit(
                arguments: ["diff", "--no-ext-diff", "--no-color", "HEAD", "--", url.lastPathComponent],
                in: url
            )
        case .success(.untracked):
            return runGit(
                arguments: ["diff", "--no-index", "--no-ext-diff", "--no-color", "/dev/null", url.lastPathComponent],
                in: url,
                successStatuses: [0, 1]
            )
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func parseSummary(from output: String) -> FileDiffSummary {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(separator: "\n").first else {
            return FileDiffSummary(additions: 0, deletions: 0)
        }

        let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        let additions = parts.indices.contains(0) ? Int(parts[0]) ?? 0 : 0
        let deletions = parts.indices.contains(1) ? Int(parts[1]) ?? 0 : 0
        return FileDiffSummary(additions: additions, deletions: deletions)
    }

    private static func fileState(for url: URL) -> Result<GitFileState, FileDiffError> {
        switch runGit(
            arguments: ["ls-files", "--error-unmatch", "--", url.lastPathComponent],
            in: url,
            successStatuses: [0, 1]
        ) {
        case let .success(output):
            let tracked = !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return .success(tracked ? .tracked : .untracked)
        case let .failure(error):
            return .failure(error)
        }
    }

    private static func runGit(
        arguments: [String],
        in fileURL: URL,
        successStatuses: Set<Int> = [0]
    ) -> Result<String, FileDiffError> {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = fileURL.deletingLastPathComponent()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(.commandFailed(error.localizedDescription))
        }

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard successStatuses.contains(Int(process.terminationStatus)) else {
            if errorOutput.localizedCaseInsensitiveContains("not a git repository") {
                return .failure(.notInGitRepository)
            }

            let message = errorOutput
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(.commandFailed(message.isEmpty ? "Unable to load diff" : message))
        }

        return .success(output)
    }
}

struct FileDiffView: View {
    let url: URL
    @Environment(\.mossTheme) private var theme
    @State private var diffContent: String = ""
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let error {
                FileDiffPlaceholder(
                    icon: "exclamationmark.triangle",
                    title: error,
                    message: "Try opening a tracked file inside a git repository."
                )
            } else if !diffContent.isEmpty {
                FileDiffScrollableContent(text: diffContent, lines: diffLines, theme: theme)
            } else if !isLoading {
                FileDiffPlaceholder(
                    icon: "checkmark.seal",
                    title: "Working tree clean",
                    message: "There are no local changes for this file."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(diffPanelBackground)
        .task(id: url) {
            loadDiff()
        }
    }

    private var diffLines: [String] {
        diffContent.components(separatedBy: "\n")
    }

    private var diffPanelBackground: Color {
        theme?.surfaceBackground.mix(with: .white, by: 0.02)
            ?? Color(nsColor: .textBackgroundColor)
    }

    private func loadDiff() {
        isLoading = true
        error = nil
        diffContent = ""

        FileDiffLoader.loadDiff(for: url) { result in
            isLoading = false
            switch result {
            case let .success(output):
                diffContent = output
                error = nil
            case let .failure(loadError):
                diffContent = ""
                error = loadError.localizedDescription
            }
        }
    }
}

private enum FileDiffMetrics {
    static let contentPadding: CGFloat = 10
    static let accentBarWidth: CGFloat = 3
    static let lineHorizontalPadding: CGFloat = 14
    static let lineVerticalPadding: CGFloat = 4
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let rowHeight = ceil(font.ascender - font.descender + font.leading) + (lineVerticalPadding * 2)
}

private enum FileDiffPalette {
    struct ScrollbarPalette {
        let thumb: NSColor
        let hover: NSColor
        let active: NSColor
    }

    static func textColor(for line: String, theme: MossTheme?) -> NSColor {
        if isMetadataLine(line) {
            return nsColor(theme?.secondaryForeground, fallback: .secondaryLabelColor)
        }
        return nsColor(theme?.foreground, fallback: .labelColor)
    }

    static func backgroundColor(for line: String, theme: MossTheme?) -> NSColor {
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
            return tintedSurfaceBackground(theme: theme, tint: addedColor, amount: 0.14)
        }
        if line.hasPrefix("-") && !line.hasPrefix("---") {
            return tintedSurfaceBackground(theme: theme, tint: removedColor, amount: 0.14)
        }
        if line.hasPrefix("@@") {
            return tintedSurfaceBackground(theme: theme, tint: hunkColor, amount: 0.12)
        }
        if isMetadataLine(line) {
            return tintedSurfaceBackground(theme: theme, tint: .white, amount: 0.03)
        }
        return .clear
    }

    static func accentBarColor(for line: String) -> NSColor {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return addedColor }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return removedColor }
        if line.hasPrefix("@@") { return hunkColor }
        return .clear
    }

    static func canvasColor(theme: MossTheme?) -> NSColor {
        mixedColor(
            nsColor(theme?.surfaceBackground, fallback: .textBackgroundColor),
            with: .white,
            amount: 0.02
        )
    }

    static func scrollbarPalette(theme: MossTheme?) -> ScrollbarPalette {
        let surfaceColor = nsColor(theme?.surfaceBackground, fallback: .textBackgroundColor)

        if isDark(surfaceColor) {
            return ScrollbarPalette(
                thumb: NSColor.white.withAlphaComponent(0.16),
                hover: NSColor.white.withAlphaComponent(0.24),
                active: NSColor.white.withAlphaComponent(0.32)
            )
        }

        let base = NSColor(srgbRed: 17 / 255, green: 24 / 255, blue: 39 / 255, alpha: 1)
        return ScrollbarPalette(
            thumb: base.withAlphaComponent(0.16),
            hover: base.withAlphaComponent(0.24),
            active: base.withAlphaComponent(0.32)
        )
    }

    private static let addedColor = NSColor(
        srgbRed: 0.31,
        green: 0.72,
        blue: 0.46,
        alpha: 1
    )
    private static let removedColor = NSColor(
        srgbRed: 0.87,
        green: 0.39,
        blue: 0.39,
        alpha: 1
    )
    private static let hunkColor = NSColor(
        srgbRed: 0.34,
        green: 0.67,
        blue: 0.92,
        alpha: 1
    )

    private static func isMetadataLine(_ line: String) -> Bool {
        line.hasPrefix("diff ") || line.hasPrefix("index ") || line.hasPrefix("---") || line.hasPrefix("+++")
    }

    private static func tintedSurfaceBackground(theme: MossTheme?, tint: NSColor, amount: CGFloat) -> NSColor {
        mixedColor(
            nsColor(theme?.surfaceBackground, fallback: .controlBackgroundColor),
            with: tint,
            amount: amount
        )
    }

    private static func nsColor(_ color: Color?, fallback: NSColor) -> NSColor {
        guard let color else { return fallback }
        return NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    }

    private static func mixedColor(_ base: NSColor, with tint: NSColor, amount: CGFloat) -> NSColor {
        let baseColor = base.usingColorSpace(.sRGB) ?? base
        let tintColor = tint.usingColorSpace(.sRGB) ?? tint
        let clampedAmount = max(0, min(amount, 1))

        return NSColor(
            srgbRed: baseColor.redComponent + ((tintColor.redComponent - baseColor.redComponent) * clampedAmount),
            green: baseColor.greenComponent + ((tintColor.greenComponent - baseColor.greenComponent) * clampedAmount),
            blue: baseColor.blueComponent + ((tintColor.blueComponent - baseColor.blueComponent) * clampedAmount),
            alpha: 1
        )
    }

    private static func isDark(_ color: NSColor) -> Bool {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let luminance = (0.299 * resolved.redComponent) + (0.587 * resolved.greenComponent) + (0.114 * resolved.blueComponent)
        return luminance < 0.5
    }
}

private struct FileDiffScrollableContent: NSViewRepresentable {
    let text: String
    let lines: [String]
    let theme: MossTheme?

    func makeNSView(context: Context) -> FileDiffTextContainerView {
        let view = FileDiffTextContainerView()
        view.update(text: text, lines: lines, theme: theme)
        return view
    }

    func updateNSView(_ nsView: FileDiffTextContainerView, context: Context) {
        nsView.update(text: text, lines: lines, theme: theme)
    }
}

@MainActor
private final class FileDiffTextContainerView: NSView {
    private let scrollView = NSScrollView()
    private let textView = FileDiffTextView()
    private var previousText: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScroller = FileDiffScroller()
        scrollView.verticalScroller = FileDiffScroller()
        scrollView.documentView = textView

        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        updateTextViewFrame()
    }

    func update(text: String, lines: [String], theme: MossTheme?) {
        let shouldResetScrollOrigin = previousText != text
        textView.update(text: text, lines: lines, theme: theme)
        (scrollView.horizontalScroller as? FileDiffScroller)?.apply(theme: theme)
        (scrollView.verticalScroller as? FileDiffScroller)?.apply(theme: theme)
        previousText = text
        needsLayout = true
        layoutSubtreeIfNeeded()

        if shouldResetScrollOrigin {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private func updateTextViewFrame() {
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let width = max(
            scrollView.contentSize.width,
            ceil(usedRect.width + (textView.textContainerInset.width * 2))
        )
        let height = max(
            scrollView.contentSize.height,
            ceil(usedRect.height + (textView.textContainerInset.height * 2))
        )

        textView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }
}

@MainActor
private final class FileDiffScroller: NSScroller {
    private var thumbColor = NSColor.white.withAlphaComponent(0.16)
    private var hoverThumbColor = NSColor.white.withAlphaComponent(0.24)
    private var activeThumbColor = NSColor.white.withAlphaComponent(0.32)
    private var isHovered = false
    private var isPressed = false
    private var hoverTrackingArea: NSTrackingArea?

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        5
    }

    override class var isCompatibleWithOverlayScrollers: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard !knobRect.isEmpty else { return }

        currentThumbColor.setFill()
        NSBezierPath(rect: knobRect).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
        super.mouseDown(with: event)
        isPressed = false
        needsDisplay = true
    }

    func apply(theme: MossTheme?) {
        let palette = FileDiffPalette.scrollbarPalette(theme: theme)
        thumbColor = palette.thumb
        hoverThumbColor = palette.hover
        activeThumbColor = palette.active
        needsDisplay = true
    }

    private var currentThumbColor: NSColor {
        if isPressed {
            return activeThumbColor
        }
        if isHovered {
            return hoverThumbColor
        }
        return thumbColor
    }
}

@MainActor
private final class FileDiffTextView: NSTextView {
    private var diffLines: [String] = []
    private var lineStartLocations: [Int] = []
    private var activeTheme: MossTheme?

    init() {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false
        textContainer.lineFragmentPadding = 0

        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        super.init(frame: .zero, textContainer: textContainer)

        drawsBackground = true
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = false
        isHorizontallyResizable = true
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainerInset = NSSize(
            width: FileDiffMetrics.contentPadding + FileDiffMetrics.accentBarWidth + FileDiffMetrics.lineHorizontalPadding,
            height: FileDiffMetrics.contentPadding
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(text: String, lines: [String], theme: MossTheme?) {
        diffLines = lines
        lineStartLocations = Self.lineStartLocations(for: lines)
        activeTheme = theme
        backgroundColor = FileDiffPalette.canvasColor(theme: theme)

        let attributedText = Self.makeAttributedText(text: text, lines: lines, theme: theme)
        textStorage?.setAttributedString(attributedText)
        needsDisplay = true
    }

    override func drawBackground(in rect: NSRect) {
        backgroundColor.setFill()
        rect.fill()

        guard
            let layoutManager,
            let textContainer,
            !diffLines.isEmpty
        else {
            return
        }

        let visibleRectInContainer = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRectInContainer, in: textContainer)

        layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphRange) { [weak self] lineRect, _, _, glyphRange, _ in
            guard let self else { return }

            let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let lineIndex = self.lineIndex(forCharacterLocation: characterRange.location)
            guard self.diffLines.indices.contains(lineIndex) else { return }

            let line = self.diffLines[lineIndex]
            let rowRect = NSRect(
                x: 0,
                y: lineRect.minY + self.textContainerOrigin.y,
                width: self.bounds.width,
                height: lineRect.height
            )

            FileDiffPalette.backgroundColor(for: line, theme: self.activeTheme).setFill()
            rowRect.fill()

            FileDiffPalette.accentBarColor(for: line).setFill()
            NSBezierPath(
                rect: NSRect(
                    x: FileDiffMetrics.contentPadding,
                    y: rowRect.minY,
                    width: FileDiffMetrics.accentBarWidth,
                    height: rowRect.height
                )
            ).fill()
        }
    }

    private func lineIndex(forCharacterLocation location: Int) -> Int {
        var candidate = 0
        for (index, startLocation) in lineStartLocations.enumerated() {
            if startLocation > location {
                break
            }
            candidate = index
        }
        return candidate
    }

    private static func lineStartLocations(for lines: [String]) -> [Int] {
        var starts: [Int] = []
        var location = 0

        for (index, line) in lines.enumerated() {
            starts.append(location)
            location += (line as NSString).length
            if index < lines.count - 1 {
                location += 1
            }
        }

        return starts
    }

    private static func makeAttributedText(text: String, lines: [String], theme: MossTheme?) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byClipping

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: FileDiffMetrics.font,
                .foregroundColor: FileDiffPalette.textColor(for: "", theme: theme),
                .paragraphStyle: paragraphStyle
            ]
        )

        var location = 0
        for (index, line) in lines.enumerated() {
            let lineLength = (line as NSString).length
            let rangeLength = lineLength + (index < lines.count - 1 ? 1 : 0)
            let range = NSRange(location: location, length: rangeLength)
            attributed.addAttribute(
                .foregroundColor,
                value: FileDiffPalette.textColor(for: line, theme: theme),
                range: range
            )
            location += rangeLength
        }

        return attributed
    }
}

private struct FileDiffPlaceholder: View {
    let icon: String
    let title: String
    let message: String
    @Environment(\.mossTheme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme?.foreground ?? .primary)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
