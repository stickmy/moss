import AppKit
import SwiftUI

struct QuickOpenPanel: View {
    let fileTreeModel: FileTreeModel
    let rootPath: String
    let onSelect: (URL) -> Void
    let onDismiss: () -> Void
    @Environment(\.mossTheme) private var theme

    @State private var query = ""
    @State private var allFiles: [FileNode] = []
    @State private var selectedIndex = 0
    @State private var isLoading = true
    @State private var eventMonitor: EventMonitor?
    @FocusState private var isSearchFocused: Bool

    private var results: [QuickOpenResult] {
        guard !query.isEmpty else {
            return allFiles.prefix(50).map {
                QuickOpenResult(node: $0, score: 0)
            }
        }
        return keywordSearch(query: query, in: allFiles, limit: 50, rootPath: rootPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryForeground)

                TextField("Search files by name…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .focused($isSearchFocused)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.secondaryForeground)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()
                .overlay((theme.border).opacity(0.5))

            // Results
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            } else if results.isEmpty {
                Text(query.isEmpty ? "No files found" : "No matches for \"\(query)\"")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.secondaryForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                QuickOpenRow(
                                    result: result,
                                    rootPath: rootPath,
                                    isSelected: index == selectedIndex,
                                    theme: theme
                                )
                                .id(result.id)
                                .onTapGesture {
                                    selectedIndex = index
                                    confirmSelection()
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: selectedIndex) { _, newIndex in
                        if newIndex < results.count {
                            proxy.scrollTo(results[newIndex].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.borderMedium, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        .onAppear {
            isSearchFocused = true
            fileTreeModel.collectAllFiles { files in
                allFiles = files
                isLoading = false
            }
            installEventMonitor()
        }
        .onDisappear {
            eventMonitor = nil
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    private func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
    }

    private func confirmSelection() {
        guard !results.isEmpty, selectedIndex < results.count else { return }
        onSelect(results[selectedIndex].node.url)
    }

    private func installEventMonitor() {
        eventMonitor = EventMonitor(.keyDown) { [self] event in
            // Don't intercept keys while IME is composing
            if event.modifierFlags.contains(.command) { return event }
            if let inputContext = NSTextInputContext.current,
               inputContext.client.markedRange().length > 0 {
                return event
            }

            switch Int(event.keyCode) {
            case 125: // Down
                moveSelection(1)
                return nil
            case 126: // Up
                moveSelection(-1)
                return nil
            case 36: // Return
                confirmSelection()
                return nil
            case 53: // Escape
                onDismiss()
                return nil
            default:
                return event
            }
        }
    }
}

// MARK: - Result Row

private struct QuickOpenRow: View {
    let result: QuickOpenResult
    let rootPath: String
    let isSelected: Bool
    let theme: MossTheme
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryForeground)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.node.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)

                Text(relativePath)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(theme.secondaryForeground.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .pointerCursor()
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovered {
            return theme.hoverBackground
        }
        return .clear
    }

    private var relativePath: String {
        let rootResolved = rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
        let dir = result.node.url.deletingLastPathComponent().path
        return dir.replacingOccurrences(of: rootResolved, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var fileIcon: String {
        let ext = result.node.url.pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "doc.text"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "py": return "doc.text"
        case "rs": return "doc.text"
        case "sh", "zsh", "bash": return "terminal"
        case "yml", "yaml", "toml": return "gearshape"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": return "photo"
        default: return "doc"
        }
    }
}

// MARK: - Fuzzy Search

struct QuickOpenResult: Identifiable {
    var id: String { node.url.path }
    let node: FileNode
    let score: Int
}

/// Matches files by checking if all space-separated keywords appear in the relative path.
private func keywordSearch(query: String, in files: [FileNode], limit: Int, rootPath: String) -> [QuickOpenResult] {
    let keywords = query.lowercased().split(separator: " ").map(String.init)
    guard !keywords.isEmpty else { return [] }

    let rootResolved = rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
    var results: [QuickOpenResult] = []

    for file in files {
        let relativePath = file.url.path
            .replacingOccurrences(of: rootResolved + "/", with: "")
        let lowerPath = relativePath.lowercased()

        // All keywords must appear in the relative path
        guard keywords.allSatisfy({ lowerPath.contains($0) }) else { continue }

        let name = file.name.lowercased()

        // Scoring: prefer filename matches, shorter paths, and earlier keyword positions
        var score = 0

        // Bonus: keywords found in filename
        let nameMatches = keywords.filter { name.contains($0) }.count
        score += nameMatches * 100

        // Bonus: exact filename match
        if keywords.count == 1 && name == keywords[0] {
            score += 500
        }

        // Bonus: filename starts with first keyword
        if name.hasPrefix(keywords[0]) {
            score += 200
        }

        // Penalty: longer paths ranked lower
        score -= relativePath.count

        results.append(QuickOpenResult(node: file, score: score))
    }

    return results.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
}
