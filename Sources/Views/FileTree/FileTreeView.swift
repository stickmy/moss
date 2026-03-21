import SwiftUI

struct FileTreeView: View {
    @Bindable var model: FileTreeModel
    @Environment(\.mossTheme) private var theme
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme?.secondaryForeground ?? .secondary)

                TextField("Search files...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme?.foreground ?? .primary)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(searchFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(searchFieldBorder, lineWidth: 1)
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if model.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let entries = filteredEntries
                if entries.isEmpty {
                    Text("No matching files")
                        .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(entries) { node in
                            FileTreeNodeView(node: node, model: model, searchText: searchText)
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .padding(.top, 2)
                }
            }
        }
        .background(theme?.background ?? Color(nsColor: .controlBackgroundColor))
    }

    private var searchFieldBackground: Color {
        theme?.surfaceBackground.mix(with: .white, by: 0.015)
            ?? Color(nsColor: .windowBackgroundColor)
    }

    private var searchFieldBorder: Color {
        (theme?.border ?? Color(nsColor: .separatorColor)).opacity(0.55)
    }

    private var filteredEntries: [FileNode] {
        if searchText.isEmpty { return model.rootEntries }
        let lower = searchText.lowercased()
        return filterNodes(model.rootEntries, search: lower)
    }

    private func filterNodes(_ nodes: [FileNode], search: String) -> [FileNode] {
        nodes.compactMap { node in
            if !node.isDirectory {
                return node.name.lowercased().contains(search) ? node : nil
            }
            if node.name.lowercased().contains(search) { return node }
            if let children = model.children(of: node) {
                let filtered = filterNodes(children, search: search)
                if !filtered.isEmpty { return node }
            }
            return nil
        }
    }
}

struct FileTreeNodeView: View {
    let node: FileNode
    @Bindable var model: FileTreeModel
    @Environment(\.mossTheme) private var theme
    var searchText: String = ""
    @State private var isHovered = false

    var body: some View {
        rowContent
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            .listRowBackground(Color.clear)
            .onHover { hovering in
                isHovered = hovering
            }
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
                        if matchesSearch(child) {
                            FileTreeNodeView(node: child, model: model, searchText: searchText)
                        }
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(4)
                }
            } label: {
                Label {
                    Text(node.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme?.foreground ?? .primary)
                } icon: {
                    Image(systemName: model.isExpanded(node) ? "folder.fill" : "folder")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(rowBackground(isSelected: false))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(rowBorder(isSelected: false), lineWidth: 1)
                }
            }
        } else {
            Label {
                Text(node.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme?.foreground ?? .primary)
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
            .onTapGesture {
                model.selectedFile = node.url
            }
        }
    }

    private var iconColor: Color {
        if model.selectedFile == node.url {
            return theme?.foreground ?? .primary
        }
        return theme?.secondaryForeground ?? .secondary
    }

    private func rowBackground(isSelected: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.14)
        }

        if isHovered {
            return (theme?.surfaceBackground ?? Color(nsColor: .windowBackgroundColor)).opacity(0.72)
        }

        return .clear
    }

    private func rowBorder(isSelected: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(0.30)
        }

        if isHovered {
            return (theme?.border ?? Color(nsColor: .separatorColor)).opacity(0.7)
        }

        return .clear
    }

    private func matchesSearch(_ node: FileNode) -> Bool {
        if searchText.isEmpty { return true }
        let lower = searchText.lowercased()
        if node.name.lowercased().contains(lower) { return true }
        if node.isDirectory, let children = model.children(of: node) {
            return children.contains { matchesSearch($0) }
        }
        return node.isDirectory
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
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc"
        }
    }
}
