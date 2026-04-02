import AppKit
import SwiftUI

struct FileTreeView: View {
    @Bindable var model: FileTreeModel
    @Environment(\.mossTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // Search trigger — clicking opens QuickOpen panel
                Button {
                    NotificationCenter.default.post(name: .quickOpenRequested, object: nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.secondaryForeground)

                        Text("Search files…")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.secondaryForeground)

                        Spacer()

                        Text("⌘P")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.secondaryForeground.opacity(0.6))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(theme.surfaceBackground.opacity(0.6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(theme.border.opacity(0.4), lineWidth: 0.5)
                            )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(searchFieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(searchFieldBorder, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .pointerCursor()

                // Refresh button — re-scans files and git status
                RefreshButton(model: model)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rootEntries.isEmpty {
                Text("Empty directory")
                    .foregroundStyle(theme.secondaryForeground)
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let _ = model.changeToken
                FileTreeKeyboardHost(model: model, theme: theme) {
                    List {
                        ForEach(model.rootEntries) { node in
                            FileTreeNodeView(node: node, model: model)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .padding(.top, 2)
                }
            }
        }
        .background(theme.background)
    }

    private var searchFieldBackground: Color {
        theme.surfaceBackground.mix(with: .white, by: 0.015)
    }

    private var searchFieldBorder: Color {
        theme.borderSubtle
    }
}

// MARK: - Refresh Button

private struct RefreshButton: View {
    let model: FileTreeModel
    @Environment(\.mossTheme) private var theme
    @State private var isHovered = false
    @State private var rotation: Double = 0

    var body: some View {
        Button {
            model.refresh()
            withAnimation(.easeInOut(duration: 0.5)) {
                rotation += 360
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryForeground)
                .rotationEffect(.degrees(rotation))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? theme.hoverBackground : .clear)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isHovered ? theme.borderMedium : .clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            isHovered = hovering
        }
        .help("Refresh files and git status")
    }
}

// MARK: - Keyboard Host

/// Wraps the file tree List with keyboard event handling.
private struct FileTreeKeyboardHost<Content: View>: NSViewRepresentable {
    let model: FileTreeModel
    let theme: MossTheme
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> FileTreeKeyboardNSView {
        let view = FileTreeKeyboardNSView()
        view.model = model
        let hostingView = NSHostingView(rootView: content())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: view.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        context.coordinator.hostingView = hostingView
        return view
    }

    func updateNSView(_ nsView: FileTreeKeyboardNSView, context: Context) {
        nsView.model = model
        context.coordinator.hostingView?.rootView = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
    }
}

/// NSView that captures keyboard events for file tree navigation.
@MainActor
final class FileTreeKeyboardNSView: NSView {
    var model: FileTreeModel?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let model else {
            super.keyDown(with: event)
            return
        }

        switch Int(event.keyCode) {
        case 125: // Down arrow
            model.moveFocus(direction: 1)
        case 126: // Up arrow
            model.moveFocus(direction: -1)
        case 123: // Left arrow
            model.collapseFocused()
        case 124: // Right arrow
            model.expandFocused()
        case 36: // Return/Enter
            model.activateFocused()
        case 49: // Space — preview focused file
            if let path = model.focusedPath,
               let node = model.visibleItems.first(where: { $0.url.path == path }),
               !node.isDirectory
            {
                model.selectedFile = node.url
            }
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - FileTreeNodeView

struct FileTreeNodeView: View {
    let node: FileNode
    @Bindable var model: FileTreeModel
    @Environment(\.mossTheme) private var theme
    @State private var isHovered = false

    private var isFocused: Bool {
        model.focusedPath == node.url.path
    }

    private var gitStatus: GitFileStatus? {
        model.gitStatusForNode(node)
    }

    var body: some View {
        rowContent
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .listRowBackground(Color.clear)
    }

    @ViewBuilder
    private var rowContent: some View {
        if node.isDirectory {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { model.isExpanded(node) },
                    set: { model.setExpanded(node, $0) }
                )
            ) {
                if let children = model.children(of: node) {
                    ForEach(children) { child in
                        FileTreeNodeView(node: child, model: model)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(4)
                }
            } label: {
                Label {
                    HStack(spacing: 0) {
                        Text(node.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(gitStatusNameColor ?? theme.foreground)

                        Spacer(minLength: 4)

                        if let status = gitStatus {
                            GitStatusBadge(status: status)
                        }
                    }
                } icon: {
                    Image(systemName: model.isExpanded(node) ? "folder.fill" : "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.secondaryForeground)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .background(rowBackground(isSelected: false))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(rowBorder(isSelected: false), lineWidth: 1)
                }
                .onHover { hovering in
                    isHovered = hovering
                }
                .onTapGesture {
                    model.focusedPath = node.url.path
                    model.setExpanded(node, !model.isExpanded(node))
                }
                .fileTreeContextMenu(node: node, model: model)
            }
        } else {
            Label {
                HStack(spacing: 0) {
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(gitStatusNameColor ?? theme.foreground)

                    Spacer(minLength: 4)

                    if let status = gitStatus {
                        GitStatusBadge(status: status)
                    }
                }
            } icon: {
                Image(systemName: fileIcon(for: node.name))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(iconColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(rowBackground(isSelected: model.selectedFile == node.url))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(rowBorder(isSelected: model.selectedFile == node.url), lineWidth: 1)
            }
            .onHover { hovering in
                isHovered = hovering
            }
            .onTapGesture {
                model.focusedPath = node.url.path
                model.selectedFile = node.url
            }
            .fileTreeContextMenu(node: node, model: model)
        }
    }

    private var iconColor: Color {
        if model.selectedFile == node.url {
            return theme.foreground
        }
        return theme.secondaryForeground
    }

    private var gitStatusNameColor: Color? {
        guard let status = gitStatus else { return nil }
        switch status {
        case .modified: return theme.gitModified
        case .added, .untracked: return theme.gitAdded
        case .deleted: return theme.gitDeleted
        case .conflict: return theme.gitDeleted
        case .renamed: return theme.gitRenamed
        }
    }

    private func rowBackground(isSelected: Bool) -> Color {
        if isFocused {
            return Color.accentColor.opacity(0.10)
        }
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }
        if isHovered {
            return theme.hoverBackground
        }
        return .clear
    }

    private func rowBorder(isSelected: Bool) -> Color {
        if isFocused {
            return Color.accentColor.opacity(0.25)
        }
        if isSelected {
            return Color.accentColor.opacity(0.30)
        }
        if isHovered {
            return theme.border.opacity(0.7)
        }
        return .clear
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
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

// MARK: - Git Status Badge

private struct GitStatusBadge: View {
    let status: GitFileStatus
    @Environment(\.mossTheme) private var theme

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private var label: String {
        switch status {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .renamed: "R"
        case .conflict: "!"
        }
    }

    private var color: Color {
        switch status {
        case .modified: theme.gitModified
        case .added, .untracked: theme.gitAdded
        case .deleted, .conflict: theme.gitDeleted
        case .renamed: theme.gitRenamed
        }
    }
}

// MARK: - Context Menu

private extension View {
    func fileTreeContextMenu(node: FileNode, model: FileTreeModel) -> some View {
        contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.url.path, forType: .string)
            }

            Button("Copy Relative Path") {
                let rootResolved = model.rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
                let relativePath = node.url.path.replacingOccurrences(of: rootResolved + "/", with: "")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(relativePath, forType: .string)
            }

            Button("Copy File Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(node.name, forType: .string)
            }

            Divider()

            Button("Reveal in Finder") {
                if node.isDirectory {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.url.path)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([node.url])
                }
            }

            if !node.isDirectory {
                Button("Open in Editor") {
                    ExternalEditorOpener.openInPreferredEditor(node.url)
                }
            }
        }
    }
}

// MARK: - External Editor Opener

enum ExternalEditorOpener {
    static func openInPreferredEditor(_ url: URL) {
        let preferredPath = UserDefaults.standard.string(forKey: "preferredExternalEditorPath") ?? ""

        if !preferredPath.isEmpty {
            let editorURL = URL(fileURLWithPath: preferredPath)
            guard FileManager.default.fileExists(atPath: preferredPath) else {
                NSWorkspace.shared.open(url)
                return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([url], withApplicationAt: editorURL, configuration: config)
            return
        }

        NSWorkspace.shared.open(url)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let quickOpenRequested = Notification.Name("quickOpenRequested")
}
