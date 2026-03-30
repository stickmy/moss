import OSLog
import SwiftUI

private let previewLogger = Logger(subsystem: "dev.moss.app", category: "FilePreview")

private let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif",
    "ico", "webp", "heic", "heif",
]

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

            case let .image(nsImage):
                ImagePreviewView(image: nsImage, fileName: url.lastPathComponent)
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
        let ext = fileURL.pathExtension.lowercased()

        // Check if it's an image
        if imageExtensions.contains(ext) {
            DispatchQueue.global(qos: .userInitiated).async {
                if let image = NSImage(contentsOf: fileURL) {
                    DispatchQueue.main.async {
                        state = .image(image)
                    }
                } else {
                    DispatchQueue.main.async {
                        state = .error("Could not load image")
                    }
                }
            }
            return
        }

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
    case image(NSImage)
    case error(String)
}

private struct FilePreviewContent {
    let text: String
    let language: PreviewLanguage?
}

// MARK: - Image Preview

private struct ImagePreviewView: View {
    let image: NSImage
    let fileName: String
    @Environment(\.mossTheme) private var theme
    @State private var scale: CGFloat = 1.0

    private var imageSize: NSSize {
        image.representations.first.map {
            NSSize(width: $0.pixelsWide, height: $0.pixelsHigh)
        } ?? image.size
    }

    var body: some View {
        VStack(spacing: 0) {
            // Image info bar
            HStack(spacing: 8) {
                Text("\(Int(imageSize.width)) × \(Int(imageSize.height))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme?.secondaryForeground ?? .secondary)

                Spacer()

                Text("\(Int(scale * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme?.secondaryForeground ?? .secondary)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { scale = max(0.1, scale - 0.25) }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { scale = min(5.0, scale + 0.25) }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { scale = 1.0 }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme?.secondaryForeground ?? .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background((theme?.surfaceBackground ?? Color(nsColor: .controlBackgroundColor)).opacity(0.6))

            Divider()
                .overlay((theme?.border ?? .clear).opacity(0.5))

            // Image display
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: imageSize.width * scale,
                        height: imageSize.height * scale
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(checkerboardPattern)
        }
    }

    /// Checkerboard pattern background for transparent images.
    private var checkerboardPattern: some View {
        Canvas { context, size in
            let cellSize: CGFloat = 10
            let light = theme?.surfaceBackground.mix(with: .white, by: 0.04) ?? Color(white: 0.15)
            let dark = theme?.surfaceBackground.mix(with: .white, by: 0.08) ?? Color(white: 0.2)

            for row in 0..<Int(ceil(size.height / cellSize)) {
                for col in 0..<Int(ceil(size.width / cellSize)) {
                    let isEven = (row + col) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(col) * cellSize,
                        y: CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    )
                    context.fill(Path(rect), with: .color(isEven ? light : dark))
                }
            }
        }
    }
}

// MARK: - Placeholder

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
