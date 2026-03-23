import AppKit
import OSLog
import STPluginNeon
import STTextView
import SwiftUI

private let previewLogger = Logger(subsystem: "dev.moss.app", category: "FilePreview")

struct FilePreviewView: View {
    let url: URL
    let wrapLines: Bool
    @Environment(\.mossTheme) private var theme
    @State private var state: FilePreviewState = .loading

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch state {
            case let .error(message):
                FilePreviewPlaceholder(
                    icon: "exclamationmark.triangle",
                    title: message,
                    message: "The file could not be rendered as plain text."
                )

            case .loading:
                FilePreviewPlaceholder(
                    icon: "doc.text.magnifyingglass",
                    title: "Loading preview",
                    message: "Preparing a source preview for this file."
                )

            case let .loaded(content):
                PreviewTextView(
                    text: content.text,
                    wrapLines: wrapLines,
                    language: content.language,
                    theme: theme
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(editorSurfaceBackground)
        .task(id: url) {
            loadFile()
        }
    }

    private func loadFile() {
        state = .loading

        let fileURL = url

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)

                let checkLen = min(data.count, 512)
                let hasBinary = data.prefix(checkLen).contains(where: { $0 == 0 })
                if hasBinary {
                    DispatchQueue.main.async {
                        state = .error("Binary file")
                    }
                    return
                }

                guard let text = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async {
                        state = .error("Binary file")
                    }
                    return
                }

                let content = FilePreviewContent(
                    text: text,
                    language: resolvedHighlightLanguage(for: fileURL)
                )

                DispatchQueue.main.async {
                    state = .loaded(content)
                }
            } catch {
                DispatchQueue.main.async {
                    state = .error(error.localizedDescription)
                }
            }
        }
    }

    private var editorSurfaceBackground: Color {
        theme?.surfaceBackground.mix(with: .white, by: 0.02)
            ?? Color(nsColor: .textBackgroundColor)
    }

    private func resolvedHighlightLanguage(for fileURL: URL) -> PreviewLanguage? {
        let language = PreviewLanguageResolver.language(for: fileURL)

        guard language != .markdown else {
            previewLogger.warning(
                "Skipping Neon markdown highlighting for \(fileURL.path, privacy: .public) because STTextView-Plugin-Neon is crashing on markdown previews in this build."
            )
            return nil
        }

        if let language {
            previewLogger.debug(
                "Using Neon highlighter for \(fileURL.lastPathComponent, privacy: .public) as \(language.debugName, privacy: .public)."
            )
        } else {
            previewLogger.debug(
                "Falling back to plain text preview for \(fileURL.lastPathComponent, privacy: .public)."
            )
        }

        return language
    }
}

private enum FilePreviewState {
    case loading
    case loaded(FilePreviewContent)
    case error(String)
}

private struct FilePreviewContent {
    let text: String
    let language: PreviewLanguage?
}

private struct PreviewTextView: NSViewRepresentable {
    let text: String
    let wrapLines: Bool
    let language: PreviewLanguage?
    let theme: MossTheme?

    func makeNSView(context: Context) -> PreviewTextContainerView {
        let view = PreviewTextContainerView()
        view.update(text: text, wrapLines: wrapLines, language: language, theme: theme)
        return view
    }

    func updateNSView(_ nsView: PreviewTextContainerView, context: Context) {
        nsView.update(text: text, wrapLines: wrapLines, language: language, theme: theme)
    }
}

@MainActor
private final class PreviewTextContainerView: NSView {
    private var scrollView: NSScrollView?
    private weak var textView: STTextView?
    private var currentLanguage: PreviewLanguage?
    private let previewFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func update(text: String, wrapLines: Bool, language: PreviewLanguage?, theme: MossTheme?) {
        if scrollView == nil || currentLanguage != language {
            rebuildTextView(text: text, wrapLines: wrapLines, language: language, theme: theme)
            return
        }

        applyBehavior(wrapLines: wrapLines)
        applyTheme(theme)

        if textView?.text != text {
            textView?.text = text
        }
    }

    private func rebuildTextView(text: String, wrapLines: Bool, language: PreviewLanguage?, theme: MossTheme?) {
        scrollView?.removeFromSuperview()

        let scrollView = STTextView.scrollableTextView(frame: bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? STTextView else {
            assertionFailure("STTextView.scrollableTextView() returned an unexpected document view")
            return
        }

        configure(textView: textView, text: text, wrapLines: wrapLines, theme: theme)

        if let language {
            installPlugin(for: language, on: textView)
        }

        addSubview(scrollView)

        self.scrollView = scrollView
        self.textView = textView
        currentLanguage = language
    }

    private func configure(textView: STTextView, text: String, wrapLines: Bool, theme: MossTheme?) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0
        paragraphStyle.lineHeightMultiple = 1

        textView.defaultParagraphStyle = paragraphStyle
        textView.isEditable = false
        textView.isSelectable = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.allowsUndo = false
        textView.highlightSelectedLine = false
        textView.showsLineNumbers = true
        textView.text = text
        textView.font = previewFont
        textView.textColor = resolvedForegroundColor(theme)
        textView.backgroundColor = resolvedEditorBackgroundColor(theme)

        applyBehavior(to: textView, wrapLines: wrapLines)
        styleGutter(of: textView, theme: theme)
    }

    private func applyBehavior(wrapLines: Bool) {
        guard let textView else { return }
        applyBehavior(to: textView, wrapLines: wrapLines)
    }

    private func applyBehavior(to textView: STTextView, wrapLines: Bool) {
        textView.isHorizontallyResizable = !wrapLines
        scrollView?.hasHorizontalScroller = !wrapLines
    }

    private func applyTheme(_ theme: MossTheme?) {
        guard let textView else { return }

        let foregroundColor = resolvedForegroundColor(theme)
        let backgroundColor = resolvedEditorBackgroundColor(theme)

        textView.textColor = foregroundColor
        textView.backgroundColor = backgroundColor
        styleGutter(of: textView, theme: theme)
    }

    private func styleGutter(of textView: STTextView, theme: MossTheme?) {
        guard let gutterView = textView.gutterView else { return }

        gutterView.font = gutterFont
        gutterView.textColor = resolvedSecondaryForegroundColor(theme)
        gutterView.selectedLineTextColor = resolvedForegroundColor(theme)
        gutterView.selectedLineHighlightColor = resolvedBorderColor(theme).withAlphaComponent(0.18)
        gutterView.separatorColor = resolvedBorderColor(theme)
        gutterView.drawSeparator = true
        gutterView.layer?.backgroundColor = resolvedGutterBackgroundColor(theme).cgColor
    }

    private func installPlugin(for language: PreviewLanguage, on textView: STTextView) {
        switch language {
        case .bash:
            textView.addPlugin(NeonPlugin(theme: .default, language: .bash))
        case .c:
            textView.addPlugin(NeonPlugin(theme: .default, language: .c))
        case .cpp:
            textView.addPlugin(NeonPlugin(theme: .default, language: .cpp))
        case .csharp:
            textView.addPlugin(NeonPlugin(theme: .default, language: .csharp))
        case .css:
            textView.addPlugin(NeonPlugin(theme: .default, language: .css))
        case .go:
            textView.addPlugin(NeonPlugin(theme: .default, language: .go))
        case .html:
            textView.addPlugin(NeonPlugin(theme: .default, language: .html))
        case .java:
            textView.addPlugin(NeonPlugin(theme: .default, language: .java))
        case .javascript:
            textView.addPlugin(NeonPlugin(theme: .default, language: .javascript))
        case .json:
            textView.addPlugin(NeonPlugin(theme: .default, language: .json))
        case .markdown:
            textView.addPlugin(NeonPlugin(theme: .default, language: .markdown))
        case .php:
            textView.addPlugin(NeonPlugin(theme: .default, language: .php))
        case .python:
            textView.addPlugin(NeonPlugin(theme: .default, language: .python))
        case .ruby:
            textView.addPlugin(NeonPlugin(theme: .default, language: .ruby))
        case .rust:
            textView.addPlugin(NeonPlugin(theme: .default, language: .rust))
        case .swift:
            textView.addPlugin(NeonPlugin(theme: .default, language: .swift))
        case .sql:
            textView.addPlugin(NeonPlugin(theme: .default, language: .sql))
        case .toml:
            textView.addPlugin(NeonPlugin(theme: .default, language: .toml))
        case .typescript:
            textView.addPlugin(NeonPlugin(theme: .default, language: .typescript))
        case .yaml:
            textView.addPlugin(NeonPlugin(theme: .default, language: .yaml))
        }
    }

    private func resolvedEditorBackgroundColor(_ theme: MossTheme?) -> NSColor {
        if let theme {
            return NSColor(theme.surfaceBackground.mix(with: .white, by: 0.02))
        }
        return NSColor.textBackgroundColor
    }

    private func resolvedGutterBackgroundColor(_ theme: MossTheme?) -> NSColor {
        if let theme {
            return NSColor(theme.surfaceBackground.mix(with: .white, by: 0.04))
        }
        return NSColor.windowBackgroundColor
    }

    private func resolvedForegroundColor(_ theme: MossTheme?) -> NSColor {
        if let theme {
            return NSColor(theme.foreground)
        }
        return NSColor.labelColor
    }

    private func resolvedSecondaryForegroundColor(_ theme: MossTheme?) -> NSColor {
        if let theme {
            return NSColor(theme.secondaryForeground)
        }
        return NSColor.secondaryLabelColor
    }

    private func resolvedBorderColor(_ theme: MossTheme?) -> NSColor {
        if let theme {
            return NSColor(theme.border)
        }
        return NSColor.separatorColor
    }
}

private struct FilePreviewPlaceholder: View {
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
