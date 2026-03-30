import AppKit
import OSLog
import SwiftUI
import WebKit

private let codeMirrorPreviewLogger = Logger(subsystem: "dev.moss.app", category: "CodeMirrorPreview")

struct CodeMirrorPreviewView: NSViewRepresentable {
    let text: String
    let wrapLines: Bool
    let language: PreviewLanguage?
    let fileName: String
    let theme: MossTheme?

    func makeNSView(context: Context) -> CodeMirrorPreviewContainerView {
        let view = CodeMirrorPreviewContainerView()
        view.update(text: text, wrapLines: wrapLines, language: language, fileName: fileName, theme: theme)
        return view
    }

    func updateNSView(_ nsView: CodeMirrorPreviewContainerView, context: Context) {
        nsView.update(text: text, wrapLines: wrapLines, language: language, fileName: fileName, theme: theme)
    }
}

@MainActor
final class CodeMirrorPreviewContainerView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private let statusPanel = NSVisualEffectView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let copyStatusButton = NSButton(title: "Copy Error", target: nil, action: nil)
    private var isPageReady = false
    private var pendingState: CodeMirrorPreviewRenderState?
    private var appliedState: CodeMirrorPreviewRenderState?
    private var currentStatusMessage: String?
    private var currentStatusKind: CodeMirrorPreviewStatusKind = .info
    private let errorLogURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Moss/CodeMirrorPreview.log")

    // Scroll position memory — static so it persists across view recreation
    private static var scrollCache: [String: Double] = [:]
    private var currentFileName: String?
    private var lastKnownScrollTop: Double = 0
    private var hasInjectedScrollListener = false

    override init(frame frameRect: NSRect) {
        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: frameRect)

        wantsLayer = true
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        contentController.add(self, name: "mossPreview")
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")

        statusPanel.translatesAutoresizingMaskIntoConstraints = false
        statusPanel.material = .sidebar
        statusPanel.blendingMode = .withinWindow
        statusPanel.state = .active
        statusPanel.wantsLayer = true
        statusPanel.layer?.cornerRadius = 10
        statusPanel.layer?.borderWidth = 1
        statusPanel.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        statusPanel.isHidden = true

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.alignment = .center
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 6
        statusLabel.lineBreakMode = .byWordWrapping

        copyStatusButton.translatesAutoresizingMaskIntoConstraints = false
        copyStatusButton.bezelStyle = .rounded
        copyStatusButton.controlSize = .small
        copyStatusButton.font = .systemFont(ofSize: 11, weight: .semibold)
        copyStatusButton.target = self
        copyStatusButton.action = #selector(copyStatusDetails)
        copyStatusButton.isHidden = true

        let statusStack = NSStackView(views: [statusLabel, copyStatusButton])
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 10

        statusPanel.addSubview(statusStack)

        addSubview(webView)
        addSubview(statusPanel)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusPanel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusPanel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            statusPanel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            statusPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            statusStack.leadingAnchor.constraint(equalTo: statusPanel.leadingAnchor, constant: 18),
            statusStack.trailingAnchor.constraint(equalTo: statusPanel.trailingAnchor, constant: -18),
            statusStack.topAnchor.constraint(equalTo: statusPanel.topAnchor, constant: 16),
            statusStack.bottomAnchor.constraint(equalTo: statusPanel.bottomAnchor, constant: -16),
        ])

        loadEditorShell()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(text: String, wrapLines: Bool, language: PreviewLanguage?, fileName: String, theme: MossTheme?) {
        // Save scroll position for the old file before switching
        if let oldFile = currentFileName, oldFile != fileName, lastKnownScrollTop > 0 {
            Self.scrollCache[oldFile] = lastKnownScrollTop
            lastKnownScrollTop = 0
        }
        currentFileName = fileName

        let state = CodeMirrorPreviewRenderState(
            text: text,
            wrapLines: wrapLines,
            languageHint: language?.debugName,
            fileName: fileName,
            theme: CodeMirrorPreviewTheme(theme: theme)
        )

        guard state != pendingState, state != appliedState else { return }
        codeMirrorPreviewLogger.debug(
            "Queueing preview state for \(fileName, privacy: .public), language=\(language?.debugName ?? "none", privacy: .public), wrap=\(wrapLines)"
        )
        pendingState = state
        sendPendingStateIfPossible()
    }

    private func loadEditorShell() {
        guard
            let indexURL = Bundle.main.url(
                forResource: "index",
                withExtension: "html",
                subdirectory: "CodeMirrorPreview"
            )
        else {
            showStatus("CodeMirror preview resources are missing.", kind: .error)
            return
        }

        codeMirrorPreviewLogger.debug("Loading CodeMirror shell from \(indexURL.path, privacy: .public)")
        showStatus("Loading CodeMirror preview…")
        webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    }

    private func sendPendingStateIfPossible() {
        guard isPageReady, let state = pendingState else {
            if !isPageReady, pendingState != nil {
                codeMirrorPreviewLogger.debug("Holding preview update until web page is ready.")
            }
            return
        }
        pendingState = nil
        appliedState = state

        guard let updateScript = state.updateScript else {
            showStatus("Failed to serialize CodeMirror preview payload.", kind: .error)
            return
        }

        codeMirrorPreviewLogger.debug(
            "Sending preview payload to web view for \(state.fileName, privacy: .public), language=\(state.languageHint ?? "none", privacy: .public)"
        )
        clearStatus()

        webView.evaluateJavaScript(updateScript) { [weak self] _, error in
            guard let self else { return }
            if let error {
                let details = self.describeJavaScriptError(error)
                codeMirrorPreviewLogger.error("CodeMirror update JS failed: \(details, privacy: .public)")
                self.showStatus("CodeMirror preview update failed: \(details)", kind: .error)
            } else {
                codeMirrorPreviewLogger.debug("CodeMirror update JS finished successfully.")
                self.restoreScrollPosition()
            }
        }
    }

    // MARK: - Scroll Position Memory

    private func injectScrollListener() {
        guard !hasInjectedScrollListener else { return }
        hasInjectedScrollListener = true

        let js = """
        (function() {
            var t;
            var scroller = document.querySelector('.cm-scroller');
            if (!scroller) return;
            scroller.addEventListener('scroll', function() {
                clearTimeout(t);
                t = setTimeout(function() {
                    window.webkit.messageHandlers.mossPreview.postMessage({
                        type: 'scroll',
                        scrollTop: scroller.scrollTop
                    });
                }, 150);
            });
        })();
        """

        webView.evaluateJavaScript(js) { _, error in
            if let error {
                codeMirrorPreviewLogger.debug("Scroll listener injection failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func restoreScrollPosition() {
        guard let fileName = currentFileName,
              let scrollTop = Self.scrollCache[fileName],
              scrollTop > 0
        else { return }

        let js = "{ var s = document.querySelector('.cm-scroller'); if (s) s.scrollTop = \(scrollTop); }"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.webView.evaluateJavaScript(js)
        }
    }

    private func showStatus(_ message: String, kind: CodeMirrorPreviewStatusKind = .info) {
        codeMirrorPreviewLogger.notice("\(message, privacy: .public)")
        currentStatusMessage = message
        currentStatusKind = kind
        statusLabel.stringValue = message
        copyStatusButton.isHidden = kind != .error
        statusPanel.isHidden = false
        if kind == .error {
            appendErrorLog(message)
        }
    }

    private func clearStatus() {
        currentStatusMessage = nil
        currentStatusKind = .info
        statusPanel.isHidden = true
        copyStatusButton.isHidden = true
    }

    private func describeJavaScriptError(_ error: Error) -> String {
        let nsError = error as NSError
        let exceptionMessage = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String
        let sourceURL = nsError.userInfo["WKJavaScriptExceptionSourceURL"] as? URL
        let lineNumber = nsError.userInfo["WKJavaScriptExceptionLineNumber"] as? NSNumber
        let columnNumber = nsError.userInfo["WKJavaScriptExceptionColumnNumber"] as? NSNumber

        var components: [String] = []
        components.append(exceptionMessage ?? error.localizedDescription)

        var location: [String] = []
        if let sourceURL {
            location.append(sourceURL.lastPathComponent)
        }
        if let lineNumber {
            if let columnNumber {
                location.append("line \(lineNumber):\(columnNumber)")
            } else {
                location.append("line \(lineNumber)")
            }
        }
        if !location.isEmpty {
            components.append("(\(location.joined(separator: ", ")))")
        }

        return components.joined(separator: " ")
    }

    @objc
    private func copyStatusDetails() {
        guard let currentStatusMessage, currentStatusKind == .error else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentStatusMessage, forType: .string)
        codeMirrorPreviewLogger.notice("Copied CodeMirror preview error to pasteboard.")
    }

    private func appendErrorLog(_ message: String) {
        let directoryURL = errorLogURL.deletingLastPathComponent()
        let timestamp = CodeMirrorPreviewTimestampFormatter.shared.string(from: Date())
        let logEntry = "[\(timestamp)] \(message)\n"

        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

            if FileManager.default.fileExists(atPath: errorLogURL.path) {
                let fileHandle = try FileHandle(forWritingTo: errorLogURL)
                defer { try? fileHandle.close() }
                try fileHandle.seekToEnd()
                if let data = logEntry.data(using: .utf8) {
                    try fileHandle.write(contentsOf: data)
                }
            } else {
                try logEntry.write(to: errorLogURL, atomically: true, encoding: .utf8)
            }

            codeMirrorPreviewLogger.debug("Appended CodeMirror preview error log to \(self.errorLogURL.path, privacy: .public)")
        } catch {
            codeMirrorPreviewLogger.error("Failed to append CodeMirror preview error log: \(error.localizedDescription, privacy: .public)")
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == "mossPreview",
            let body = message.body as? [String: Any],
            let type = body["type"] as? String
        else {
            codeMirrorPreviewLogger.error("Received malformed script message from CodeMirror preview.")
            return
        }

        switch type {
        case "ready":
            codeMirrorPreviewLogger.debug("Received ready message from CodeMirror preview.")
            isPageReady = true
            clearStatus()
            injectScrollListener()
            sendPendingStateIfPossible()
        case "debug":
            if let text = body["message"] as? String {
                codeMirrorPreviewLogger.debug("JS: \(text, privacy: .public)")
            }
        case "error":
            if let text = body["message"] as? String {
                codeMirrorPreviewLogger.error("JS: \(text, privacy: .public)")
                showStatus(text, kind: .error)
            }
        case "scroll":
            if let scrollTop = body["scrollTop"] as? Double {
                lastKnownScrollTop = scrollTop
            }
        default:
            codeMirrorPreviewLogger.debug("Ignoring CodeMirror preview message of type \(type, privacy: .public)")
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        codeMirrorPreviewLogger.debug("WKWebView didFinish for CodeMirror preview.")
        if !isPageReady {
            showStatus("Initializing CodeMirror…")
            webView.evaluateJavaScript(
                "({readyState: document.readyState, hasPreview: typeof window.mossPreview !== 'undefined'})"
            ) { _, error in
                if let error {
                    codeMirrorPreviewLogger.error("didFinish probe failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    codeMirrorPreviewLogger.debug("didFinish probe evaluated.")
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        codeMirrorPreviewLogger.error("WKWebView navigation failed: \(error.localizedDescription, privacy: .public)")
        showStatus("CodeMirror preview failed to load: \(error.localizedDescription)", kind: .error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        codeMirrorPreviewLogger.error("WKWebView provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        showStatus("CodeMirror preview failed to load: \(error.localizedDescription)", kind: .error)
    }
}

private enum CodeMirrorPreviewStatusKind {
    case info
    case error
}

private enum CodeMirrorPreviewTimestampFormatter {
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct CodeMirrorPreviewRenderState: Equatable {
    let text: String
    let wrapLines: Bool
    let languageHint: String?
    let fileName: String
    let theme: CodeMirrorPreviewTheme

    var updateScript: String? {
        let payload = [
            "text": text,
            "wrapLines": wrapLines,
            "languageHint": languageHint ?? NSNull(),
            "fileName": fileName,
            "theme": theme.scriptValue,
        ] as [String: Any]

        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return "window.mossPreview && window.mossPreview.update(\(json));"
    }
}

private struct CodeMirrorPreviewTheme: Equatable {
    let background: String
    let gutterBackground: String
    let gutterBorder: String
    let foreground: String
    let secondaryForeground: String
    let selectionBackground: String
    let isDark: Bool

    init(theme: MossTheme?) {
        let backgroundColor = CodeMirrorPreviewTheme.color(
            theme?.surfaceBackground.mix(with: .white, by: 0.02),
            fallback: .textBackgroundColor
        )
        let gutterBackgroundColor = CodeMirrorPreviewTheme.color(
            theme?.surfaceBackground.mix(with: .white, by: 0.04),
            fallback: .windowBackgroundColor
        )
        let borderColor = CodeMirrorPreviewTheme.color(theme?.border, fallback: .separatorColor)
        let foregroundColor = CodeMirrorPreviewTheme.color(theme?.foreground, fallback: .labelColor)
        let secondaryForegroundColor = CodeMirrorPreviewTheme.color(
            theme?.secondaryForeground,
            fallback: .secondaryLabelColor
        )

        self.background = CodeMirrorPreviewTheme.cssColor(backgroundColor)
        self.gutterBackground = CodeMirrorPreviewTheme.cssColor(gutterBackgroundColor)
        self.gutterBorder = CodeMirrorPreviewTheme.cssColor(borderColor)
        self.foreground = CodeMirrorPreviewTheme.cssColor(foregroundColor)
        self.secondaryForeground = CodeMirrorPreviewTheme.cssColor(secondaryForegroundColor)
        self.selectionBackground = CodeMirrorPreviewTheme.cssColor(borderColor.withAlphaComponent(0.18))
        self.isDark = CodeMirrorPreviewTheme.isDark(backgroundColor)
    }

    var scriptValue: [String: Any] {
        [
            "background": background,
            "gutterBackground": gutterBackground,
            "gutterBorder": gutterBorder,
            "foreground": foreground,
            "secondaryForeground": secondaryForeground,
            "selectionBackground": selectionBackground,
            "isDark": isDark,
        ]
    }

    private static func color(_ color: Color?, fallback: NSColor) -> NSColor {
        let resolved = color.map(NSColor.init) ?? fallback
        return resolved.usingColorSpace(.sRGB) ?? resolved
    }

    private static func cssColor(_ color: NSColor) -> String {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let red = Int(round(resolved.redComponent * 255))
        let green = Int(round(resolved.greenComponent * 255))
        let blue = Int(round(resolved.blueComponent * 255))
        let alpha = resolved.alphaComponent

        if alpha < 0.999 {
            return "rgba(\(red), \(green), \(blue), \(alpha))"
        }

        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func isDark(_ color: NSColor) -> Bool {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        let luminance = (0.299 * resolved.redComponent) + (0.587 * resolved.greenComponent) + (0.114 * resolved.blueComponent)
        return luminance < 0.5
    }
}
