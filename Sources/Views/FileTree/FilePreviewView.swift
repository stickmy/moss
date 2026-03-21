import SwiftUI

struct FilePreviewView: View {
    let url: URL
    let wrapLines: Bool
    @Environment(\.mossTheme) private var theme
    @State private var lines: [AttributedString] = []
    @State private var plainLines: [String] = []
    @State private var error: String?
    @State private var isLoading = false
    private let lineContentHorizontalPadding: CGFloat = 8
    private let lineContentVerticalPadding: CGFloat = 4
    private let gutterTrailingPadding: CGFloat = 6
    private let gutterDividerWidth: CGFloat = 1

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let error {
                    FilePreviewPlaceholder(
                        icon: "exclamationmark.triangle",
                        title: error,
                        message: "The file could not be rendered as plain text."
                    )
                } else if isLoading {
                    FilePreviewPlaceholder(
                        icon: "doc.text.magnifyingglass",
                        title: "Loading preview",
                        message: "Preparing a syntax-highlighted view of this file."
                    )
                } else {
                    ScrollView(scrollAxes) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(plainLines.enumerated()), id: \.offset) { idx, _ in
                                HStack(alignment: .top, spacing: 0) {
                                    Text("\(idx + 1)")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                                        .frame(width: lineNumberWidth, alignment: .trailing)
                                        .padding(.trailing, gutterTrailingPadding)
                                        .padding(.vertical, lineContentVerticalPadding)
                                        .background(gutterBackground)

                                    Rectangle()
                                        .fill(gutterDivider)
                                        .frame(width: gutterDividerWidth)

                                    lineContentView(
                                        at: idx,
                                        wrappedContentWidth: wrappedContentWidth(in: proxy.size.width)
                                    )
                                }
                                .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
                                .background(rowBackground(for: idx))
                            }
                        }
                        .fixedSize(horizontal: !wrapLines, vertical: false)
                        .frame(
                            minWidth: proxy.size.width,
                            minHeight: proxy.size.height,
                            alignment: .topLeading
                        )
                    }
                    .id(wrapLines)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(editorSurfaceBackground)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(theme?.background ?? Color(nsColor: .controlBackgroundColor))
        .task(id: url) {
            loadFile()
        }
    }

    private func loadFile() {
        isLoading = true
        error = nil
        lines = []
        plainLines = []

        let fileURL = url

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)

                // Quick binary check on first 512 bytes
                let checkLen = min(data.count, 512)
                let hasBinary = data.prefix(checkLen).contains(where: { $0 == 0 })
                if hasBinary {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.error = "Binary file"
                    }
                    return
                }

                guard let text = String(data: data, encoding: .utf8) else {
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.error = "Binary file"
                    }
                    return
                }

                let rawLines = text.components(separatedBy: "\n")
                let language = SyntaxHighlighter.language(for: fileURL)
                let highlighted = SyntaxHighlighter.shared.highlightLines(text, language: language)

                DispatchQueue.main.async {
                    self.plainLines = rawLines
                    self.lines = highlighted
                    self.error = nil
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func rowBackground(for index: Int) -> Color {
        if index.isMultiple(of: 2) {
            return (theme?.surfaceBackground ?? Color.clear).opacity(0.18)
        }
        return .clear
    }

    @ViewBuilder
    private func lineContentView(at index: Int, wrappedContentWidth: CGFloat) -> some View {
        Group {
            if index < lines.count {
                lineTextView(
                    Text(lines[index])
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .textSelection(.enabled),
                    wrappedContentWidth: wrappedContentWidth
                )
            } else {
                lineTextView(
                    Text(plainLines[index].isEmpty ? " " : plainLines[index])
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(theme?.foreground ?? .primary)
                        .textSelection(.enabled),
                    wrappedContentWidth: wrappedContentWidth
                )
            }
        }
    }

    @ViewBuilder
    private func lineTextView<Content: View>(_ text: Content, wrappedContentWidth: CGFloat) -> some View {
        if wrapLines {
            text
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .lineSpacing(0)
                .padding(.horizontal, lineContentHorizontalPadding)
                .padding(.vertical, lineContentVerticalPadding)
                .frame(width: wrappedContentWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            text
                .lineLimit(1)
                .padding(.horizontal, lineContentHorizontalPadding)
                .padding(.vertical, lineContentVerticalPadding)
                .fixedSize(horizontal: true, vertical: true)
        }
    }

    private func wrappedContentWidth(in containerWidth: CGFloat) -> CGFloat {
        max(120, containerWidth - lineNumberWidth - gutterTrailingPadding - gutterDividerWidth)
    }

    private var scrollAxes: Axis.Set {
        wrapLines ? .vertical : [.horizontal, .vertical]
    }

    private var lineNumberWidth: CGFloat {
        let digits = max(2, String(max(plainLines.count, 1)).count)
        return CGFloat(8 + digits * 7)
    }

    private var gutterBackground: Color {
        theme?.surfaceBackground.mix(with: .white, by: 0.04)
            ?? Color(nsColor: .windowBackgroundColor)
    }

    private var gutterDivider: Color {
        (theme?.border ?? Color(nsColor: .separatorColor)).opacity(0.55)
    }

    private var editorSurfaceBackground: Color {
        theme?.surfaceBackground.mix(with: .white, by: 0.02)
            ?? Color(nsColor: .textBackgroundColor)
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
