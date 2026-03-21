import Foundation

@MainActor
@Observable
final class FileTreeModel {
    var rootPath: String
    var rootEntries: [FileNode] = []
    var isLoading = false
    var expandedPaths: Set<String> = []
    var selectedFile: URL?

    /// Lazily loaded children, keyed by parent directory path.
    var loadedChildren: [String: [FileNode]] = [:]

    init(rootPath: String) {
        self.rootPath = rootPath
        reload()
    }

    func updateRootPath(_ newPath: String) {
        guard newPath != rootPath else { return }
        rootPath = newPath
        reload()
    }

    func reload() {
        let path = rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
        isLoading = true
        expandedPaths = [path]
        loadedChildren = [:]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = Self.scanChildren(of: URL(fileURLWithPath: path))
            DispatchQueue.main.async {
                self?.rootEntries = entries
                self?.loadedChildren[path] = entries
                self?.isLoading = false
            }
        }
    }

    func isExpanded(_ node: FileNode) -> Bool {
        expandedPaths.contains(node.url.path)
    }

    func setExpanded(_ node: FileNode, _ expanded: Bool) {
        if expanded {
            expandedPaths.insert(node.url.path)
            if loadedChildren[node.url.path] == nil {
                loadChildren(for: node)
            }
        } else {
            expandedPaths.remove(node.url.path)
        }
    }

    func children(of node: FileNode) -> [FileNode]? {
        loadedChildren[node.url.path]
    }

    private func loadChildren(for node: FileNode) {
        let url = node.url
        let path = url.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let children = Self.scanChildren(of: url)
            DispatchQueue.main.async {
                self?.loadedChildren[path] = children
            }
        }
    }

    /// Returns sorted children of a directory (shallow, one level).
    private static func scanChildren(of url: URL) -> [FileNode] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents.map { childURL in
            let isDir = (try? childURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) ?? false
            return FileNode(
                url: childURL,
                name: childURL.lastPathComponent,
                isDirectory: isDir
            )
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }
}

struct FileNode: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.url.path == rhs.url.path
    }
}
