import OSLog
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
                CodeMirrorPreviewView(
                    text: content.text,
                    wrapLines: wrapLines,
                    language: content.language,
                    fileName: url.lastPathComponent,
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

        if let language {
            previewLogger.debug(
                "Using CodeMirror highlighter for \(fileURL.lastPathComponent, privacy: .public) as \(language.debugName, privacy: .public)."
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
