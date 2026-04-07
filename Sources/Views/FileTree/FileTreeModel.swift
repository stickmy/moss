import Foundation

// MARK: - Git File Status

enum GitFileStatus: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"
    case conflict = "U"
}

// MARK: - FileTreeModel

@MainActor
@Observable
final class FileTreeModel {
    var rootPath: String
    var rootEntries: [FileNode] = []
    var isLoading = false
    var expandedPaths: Set<String> = []
    var selectedFile: URL?
    var focusedPath: String?

    /// Lazily loaded children, keyed by parent directory path.
    var loadedChildren: [String: [FileNode]] = [:]

    /// Git status for files, keyed by absolute path.
    var gitStatus: [String: GitFileStatus] = [:]

    /// Incremented on every FSEvent batch to force view re-evaluation.
    var changeToken: Int = 0

    private let watcher = FileSystemWatcher()

    init(rootPath: String) {
        self.rootPath = rootPath
        watcher.onChange = { [weak self] paths in
            self?.handleFSEvents(paths: paths)
        }
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
                self?.watcher.start(path: path)
                self?.refreshGitStatus()
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
            options: []
        )) ?? []

        return contents.compactMap { childURL in
            let name = childURL.lastPathComponent
            let isDir = (try? childURL.resourceValues(
                forKeys: [.isDirectoryKey]
            ).isDirectory) ?? false
            if isDir && ignoredDirectories.contains(name) { return nil }
            return FileNode(
                url: childURL,
                name: name,
                isDirectory: isDir
            )
        }.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - FSEvents Handling

    private func handleFSEvents(paths: [String]) {
        var affectedDirs: Set<String> = []
        for path in paths {
            let dir = (path as NSString).deletingLastPathComponent
            if loadedChildren[dir] != nil {
                affectedDirs.insert(dir)
            }
            if loadedChildren[path] != nil {
                affectedDirs.insert(path)
            }
        }

        guard !affectedDirs.isEmpty else { return }

        for dir in affectedDirs {
            reloadDirectory(dir)
        }

        changeToken &+= 1
        refreshGitStatus()
    }

    private func reloadDirectory(_ dirPath: String) {
        let url = URL(fileURLWithPath: dirPath)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let children = Self.scanChildren(of: url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadedChildren[dirPath] = children
                let rootResolved = self.rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
                if dirPath == rootResolved {
                    self.rootEntries = children
                }
            }
        }
    }

    // MARK: - Manual Refresh

    /// Re-scans all loaded directories and refreshes git status without collapsing the tree.
    func refresh() {
        let path = rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
        let dirsToReload = Array(loadedChildren.keys)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var updated: [String: [FileNode]] = [:]
            for dir in dirsToReload {
                updated[dir] = Self.scanChildren(of: URL(fileURLWithPath: dir))
            }
            DispatchQueue.main.async {
                guard let self else { return }
                for (dir, children) in updated {
                    self.loadedChildren[dir] = children
                    if dir == path {
                        self.rootEntries = children
                    }
                }
                self.changeToken &+= 1
                self.refreshGitStatus()
            }
        }
    }

    // MARK: - Git Status

    func refreshGitStatus() {
        let path = rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let statusMap = GitStatusProvider.status(in: path)
            DispatchQueue.main.async {
                self?.gitStatus = statusMap
            }
        }
    }

    /// Returns the git status for a node. For directories, inherits from children.
    func gitStatusForNode(_ node: FileNode) -> GitFileStatus? {
        if !node.isDirectory {
            return gitStatus[node.url.path]
        }

        let prefix = node.url.path + "/"
        let childStatuses = gitStatus.filter { $0.key.hasPrefix(prefix) }.values
        guard !childStatuses.isEmpty else { return nil }

        if childStatuses.contains(.conflict) { return .conflict }
        if childStatuses.contains(.modified) { return .modified }
        if childStatuses.contains(.added) { return .added }
        if childStatuses.contains(.untracked) { return .untracked }
        return .modified
    }

    // MARK: - Keyboard Navigation

    var visibleItems: [FileNode] {
        var items: [FileNode] = []
        collectVisibleItems(from: rootEntries, into: &items)
        return items
    }

    private func collectVisibleItems(from nodes: [FileNode], into items: inout [FileNode]) {
        for node in nodes {
            items.append(node)
            if node.isDirectory && expandedPaths.contains(node.url.path) {
                if let children = loadedChildren[node.url.path] {
                    collectVisibleItems(from: children, into: &items)
                }
            }
        }
    }

    func moveFocus(direction: Int) {
        let visible = visibleItems
        guard !visible.isEmpty else { return }

        if let current = focusedPath,
           let index = visible.firstIndex(where: { $0.url.path == current })
        {
            let newIndex = max(0, min(visible.count - 1, index + direction))
            focusedPath = visible[newIndex].url.path
        } else {
            focusedPath = visible.first?.url.path
        }
    }

    func activateFocused() {
        guard let focusedPath,
              let node = visibleItems.first(where: { $0.url.path == focusedPath })
        else { return }

        if node.isDirectory {
            setExpanded(node, !isExpanded(node))
        } else {
            selectedFile = node.url
        }
    }

    func collapseFocused() {
        guard let focusedPath,
              let node = visibleItems.first(where: { $0.url.path == focusedPath })
        else { return }

        if node.isDirectory && isExpanded(node) {
            setExpanded(node, false)
        } else {
            let parentPath = (focusedPath as NSString).deletingLastPathComponent
            if let parent = visibleItems.first(where: { $0.url.path == parentPath }) {
                self.focusedPath = parent.url.path
            }
        }
    }

    func expandFocused() {
        guard let focusedPath,
              let node = visibleItems.first(where: { $0.url.path == focusedPath })
        else { return }

        if node.isDirectory {
            if !isExpanded(node) {
                setExpanded(node, true)
            } else if let children = loadedChildren[node.url.path], let first = children.first {
                self.focusedPath = first.url.path
            }
        }
    }

    // MARK: - File Collection (for Quick Open)

    func collectAllFiles(completion: @escaping ([FileNode]) -> Void) {
        let path = rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
        DispatchQueue.global(qos: .userInitiated).async {
            var files: [FileNode] = []
            Self.collectFilesRecursively(
                in: URL(fileURLWithPath: path),
                into: &files,
                limit: 10000
            )
            DispatchQueue.main.async {
                completion(files)
            }
        }
    }

    private static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "DerivedData",
        ".swiftpm", "Pods", ".next", "dist", "__pycache__",
        ".cache", ".venv", "venv", "target", ".gradle",
        ".xcodeproj", ".xcworkspace",
    ]

    private static func collectFilesRecursively(
        in url: URL,
        into files: inout [FileNode],
        limit: Int
    ) {
        guard files.count < limit else { return }

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        for childURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard files.count < limit else { return }

            let isDir = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if isDir {
                if !ignoredDirectories.contains(childURL.lastPathComponent) {
                    collectFilesRecursively(in: childURL, into: &files, limit: limit)
                }
            } else {
                files.append(FileNode(
                    url: childURL,
                    name: childURL.lastPathComponent,
                    isDirectory: false
                ))
            }
        }
    }
}

// MARK: - FileNode

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
