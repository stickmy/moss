import OSLog
import SwiftUI

private let previewLogger = Logger(subsystem: "dev.moss.app", category: "FilePreview")

private let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif",
    "ico", "webp", "heic", "heif",
]

private let markdownExtensions: Set<String> = [
    "md", "markdown", "mdown", "mkd",
]

func debugLog(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: "/tmp/moss_preview_debug.log") {
            if let fh = FileHandle(forWritingAtPath: "/tmp/moss_preview_debug.log") {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: "/tmp/moss_preview_debug.log", contents: data)
        }
    }
}

struct FilePreviewView: View {
    let url: URL
    var wrapLines: Bool = false
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

            case let .loaded(text):
                NativeCodePreviewView(
                    text: text,
                    fileURL: url,
                    theme: theme,
                    wrapLines: wrapLines
                )

            case let .markdown(text):
                MarkdownPreviewView(text: text)

            case let .image(nsImage):
                ImagePreviewView(image: nsImage, fileName: url.lastPathComponent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: url) {
            loadFile()
        }
    }

    private func loadFile() {
        state = .loading

        let fileURL = url
        let ext = fileURL.pathExtension.lowercased()

        if imageExtensions.contains(ext) {
            DispatchQueue.global(qos: .userInitiated).async {
                if let image = NSImage(contentsOf: fileURL) {
                    DispatchQueue.main.async { state = .image(image) }
                } else {
                    DispatchQueue.main.async { state = .error("Could not load image") }
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
                    DispatchQueue.main.async { state = .error("Binary file") }
                    return
                }

                guard let text = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async { state = .error("Binary file") }
                    return
                }

                let isMarkdown = markdownExtensions.contains(ext)
                DispatchQueue.main.async {
                    state = isMarkdown ? .markdown(text) : .loaded(text)
                }
            } catch {
                DispatchQueue.main.async { state = .error(error.localizedDescription) }
            }
        }
    }

    private var editorSurfaceBackground: Color {
        theme.elevatedBackground
    }
}

private enum FilePreviewState {
    case loading
    case loaded(String)
    case markdown(String)
    case image(NSImage)
    case error(String)
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
                    .foregroundStyle(theme.secondaryForeground)

                Spacer()

                Text("\(Int(scale * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.secondaryForeground)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { scale = max(0.1, scale - 0.25) }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryForeground)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { scale = min(5.0, scale + 0.25) }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryForeground)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { scale = 1.0 }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryForeground)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(theme.surfaceBackground.opacity(0.6))

            Divider()
                .overlay(theme.border.opacity(0.5))

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
            let light = theme.raisedBackground
            let dark = theme.prominentBackground

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
                .foregroundStyle(theme.secondaryForeground)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.foreground)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
