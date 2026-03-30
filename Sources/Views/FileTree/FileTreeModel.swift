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

// MARK: - FSEvents Helper

/// Weak reference wrapper for safe FSEvents callback routing.
private final class FSEventsHelper: @unchecked Sendable {
    weak var model: FileTreeModel?
    init(model: FileTreeModel) { self.model = model }
}

/// Module-level C callback for FSEvents.
private let fileTreeFSCallback: FSEventStreamCallback = {
    (_, clientCallBackInfo, numEvents, eventPaths, _, _) in
    guard let clientCallBackInfo else { return }
    let helper = Unmanaged<FSEventsHelper>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    guard let model = helper.model else { return }

    let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    for i in 0..<CFArrayGetCount(cfArray) {
        if let val = CFArrayGetValueAtIndex(cfArray, i) {
            paths.append(Unmanaged<CFString>.fromOpaque(val).takeUnretainedValue() as String)
        }
    }

    DispatchQueue.main.async {
        model.handleFSEvents(paths: paths)
    }
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

    /// FSEvents stream for watching file system changes.
    private nonisolated(unsafe) var fsEventStreamRef: FSEventStreamRef?
    private nonisolated(unsafe) var fsEventsHelperRetained: Unmanaged<FSEventsHelper>?

    init(rootPath: String) {
        self.rootPath = rootPath
        reload()
    }

    deinit {
        stopWatching()
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
                self?.startWatching()
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

    // MARK: - File System Watching (FSEvents)

    func startWatching() {
        stopWatching()
        let path = rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
        let pathsToWatch = [path] as CFArray

        let helper = FSEventsHelper(model: self)
        let retained = Unmanaged.passRetained(helper)
        fsEventsHelperRetained = retained

        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            nil,
            fileTreeFSCallback,
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.5,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            retained.release()
            fsEventsHelperRetained = nil
            return
        }

        FSEventStreamScheduleWithRunLoop(stream, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        FSEventStreamStart(stream)
        fsEventStreamRef = stream
    }

    nonisolated func stopWatching() {
        if let stream = fsEventStreamRef {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStreamRef = nil
        }
        fsEventsHelperRetained?.release()
        fsEventsHelperRetained = nil
    }

    func handleFSEvents(paths: [String]) {
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

        for dir in affectedDirs {
            reloadDirectory(dir)
        }

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

    // MARK: - Git Status

    func refreshGitStatus() {
        let path = rootPath.replacingOccurrences(of: "~", with: NSHomeDirectory())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let statusMap = Self.parseGitStatus(in: path)
            DispatchQueue.main.async {
                self?.gitStatus = statusMap
            }
        }
    }

    private static func parseGitStatus(in directory: String) -> [String: GitFileStatus] {
        // Find git root first
        let rootPipe = Pipe()
        let rootProcess = Process()
        rootProcess.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        rootProcess.arguments = ["rev-parse", "--show-toplevel"]
        rootProcess.currentDirectoryURL = URL(fileURLWithPath: directory)
        rootProcess.standardOutput = rootPipe
        rootProcess.standardError = Pipe()

        var gitRoot = directory
        do {
            try rootProcess.run()
            rootProcess.waitUntilExit()
            let rootData = rootPipe.fileHandleForReading.readDataToEndOfFile()
            if let root = String(data: rootData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty
            {
                gitRoot = root
            }
        } catch {
            return [:]
        }

        // Get porcelain status
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain", "-uall"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [:] }

        var result: [String: GitFileStatus] = [:]

        for line in output.components(separatedBy: "\n") where line.count >= 4 {
            let indexStatus = line[line.index(line.startIndex, offsetBy: 0)]
            let workTreeStatus = line[line.index(line.startIndex, offsetBy: 1)]
            let filePath = String(line.dropFirst(3))

            let absPath = (gitRoot as NSString).appendingPathComponent(filePath)

            let status: GitFileStatus
            if indexStatus == "?" && workTreeStatus == "?" {
                status = .untracked
            } else if indexStatus == "A" || workTreeStatus == "A" {
                status = .added
            } else if indexStatus == "D" || workTreeStatus == "D" {
                status = .deleted
            } else if indexStatus == "R" || workTreeStatus == "R" {
                status = .renamed
            } else if indexStatus == "U" || workTreeStatus == "U" {
                status = .conflict
            } else if indexStatus == "M" || workTreeStatus == "M" {
                status = .modified
            } else {
                continue
            }

            result[absPath] = status
        }

        return result
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
            options: [.skipsHiddenFiles]
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
