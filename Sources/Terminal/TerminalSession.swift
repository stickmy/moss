import Foundation
import AppKit

struct TrackedTask: Identifiable {
    let id: String
    let subject: String
    var isDone: Bool = false
}

@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id: UUID
    let terminalApp: MossTerminalApp
    let socketPath: String
    let launchDirectory: String
    let initialLeafId: UUID
    var splitRoot: TerminalSplitNode
    private(set) var activeSurfaceId: UUID?
    var title: String = ""
    var status: AgentStatus = .none
    private var manualStatus: AgentStatus = .none
    private var automaticStatus: AgentStatus = .none
    private var desktopNotificationPending = false
    var isFocused: Bool = false
    var workingDirectory: String = "~"
    var gitBranch: String?
    var onClose: (() -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    @ObservationIgnored private var surfaceViewCache: [UUID: MossSurfaceView] = [:]
    @ObservationIgnored private var surfaceHostViewCache: [UUID: MossSurfaceHostView] = [:]
    private nonisolated(unsafe) var gitWatcher: DispatchSourceFileSystemObject?
    var agentSessionId: String?
    var trackedTasks: [TrackedTask] = []
    /// One-line dynamic summary shown in card header (e.g. prompt text, waiting reason).
    var activitySummary: String?

    /// Search state — non-nil when search overlay is active.
    var searchState: TerminalSearchState?
    @ObservationIgnored private var searchDebounceTask: Task<Void, Never>?

    /// Per-session file tree state (expansion, selected file) — persists across focus switches.
    private var _fileTreeModel: FileTreeModel?
    var fileTreeModel: FileTreeModel {
        if let m = _fileTreeModel { return m }
        let m = FileTreeModel(rootPath: workingDirectory)
        _fileTreeModel = m
        return m
    }

    init(
        id: UUID = UUID(),
        terminalApp: MossTerminalApp,
        socketPath: String,
        launchDirectory: String? = nil
    ) {
        let resolvedLaunchDirectory = Self.resolveDirectory(launchDirectory)
        let leafId = UUID()
        self.id = id
        self.terminalApp = terminalApp
        self.socketPath = socketPath
        self.launchDirectory = resolvedLaunchDirectory
        self.workingDirectory = resolvedLaunchDirectory
        self.initialLeafId = leafId
        self.splitRoot = .leaf(id: leafId)
        self.activeSurfaceId = leafId
    }

    func setManualStatus(_ status: AgentStatus) {
        manualStatus = status
        updateDisplayedStatus()
    }

    func setAutomaticStatus(_ status: AgentStatus) {
        automaticStatus = status
        if status == .running {
            activitySummary = nil
        }
        updateDisplayedStatus()
    }

    private func updateDisplayedStatus() {
        let nextStatus: AgentStatus

        if manualStatus != .none {
            nextStatus = manualStatus
        } else if desktopNotificationPending {
            nextStatus = .waiting
        } else {
            nextStatus = automaticStatus
        }

        guard status != nextStatus else { return }

        let previousStatus = status
        status = nextStatus

        if nextStatus == .waiting && previousStatus != .waiting {
            AgentNotificationManager.shared.postAgentWaiting(
                sessionId: id,
                sessionTitle: title
            )
        }
    }

    // MARK: - Claude Session

    func startAgentSession(id: String) {
        guard agentSessionId != id else { return }
        agentSessionId = id
        activitySummary = nil
        resetTrackedTasks()
    }

    // MARK: - Activity Summary

    func setActivity(_ text: String?) {
        activitySummary = text?.isEmpty == true ? nil : text
    }

    // MARK: - Task Tracking

    func addTrackedTask(id: String, subject: String) {
        guard !trackedTasks.contains(where: { $0.id == id }) else { return }
        var updated = trackedTasks
        updated.append(TrackedTask(id: id, subject: subject, isDone: false))
        trackedTasks = updated
        NotificationCenter.default.post(name: .trackedTasksChanged, object: self)
    }

    func completeTrackedTask(id: String) {
        guard let index = trackedTasks.firstIndex(where: { $0.id == id }) else { return }
        var updated = trackedTasks
        updated[index].isDone = true

        if updated.allSatisfy(\.isDone) {
            trackedTasks = []
        } else {
            trackedTasks = updated
        }
        NotificationCenter.default.post(name: .trackedTasksChanged, object: self)
    }

    func resetTrackedTasks() {
        trackedTasks.removeAll()
        NotificationCenter.default.post(name: .trackedTasksChanged, object: self)
    }

    func handleDesktopNotification(title: String, body: String) {
        desktopNotificationPending = true
        updateDisplayedStatus()
    }

    func acknowledgeDesktopNotificationPending() {
        guard desktopNotificationPending else { return }
        desktopNotificationPending = false
        updateDisplayedStatus()
    }

    // MARK: - Surface View Cache

    func surfaceView(for leafId: UUID) -> MossSurfaceView {
        if let cached = surfaceViewCache[leafId] {
            return cached
        }
        let view = MossSurfaceView(
            terminalApp: terminalApp,
            sessionId: id,
            workingDirectory: launchDirectory,
            socketPath: socketPath
        )
        view.delegate = self
        view.leafId = leafId
        surfaceViewCache[leafId] = view
        splitDebugLog(
            "TerminalSession.surfaceView create leaf=\(leafId) session=\(id) " +
            "surface=\(debugObjectID(view))"
        )
        return view
    }

    func surfaceHostView(for leafId: UUID) -> MossSurfaceHostView {
        if let cached = surfaceHostViewCache[leafId] {
            splitDebugLog(
                "TerminalSession.surfaceHostView reuse leaf=\(leafId) session=\(id) " +
                "host=\(debugObjectID(cached)) surface=\(debugObjectID(cached.surfaceView))"
            )
            return cached
        }

        let hostView = MossSurfaceHostView(surfaceView: surfaceView(for: leafId))
        surfaceHostViewCache[leafId] = hostView
        splitDebugLog(
            "TerminalSession.surfaceHostView create leaf=\(leafId) session=\(id) " +
            "host=\(debugObjectID(hostView)) surface=\(debugObjectID(hostView.surfaceView))"
        )
        return hostView
    }

    func removeCachedSurface(for leafId: UUID) {
        splitDebugLog(
            "TerminalSession.removeCachedSurface leaf=\(leafId) session=\(id) " +
            "host=\(debugObjectID(surfaceHostViewCache[leafId])) surface=\(debugObjectID(surfaceViewCache[leafId]))"
        )
        surfaceHostViewCache.removeValue(forKey: leafId)
        surfaceViewCache.removeValue(forKey: leafId)
    }

    // MARK: - Split Management

    func splitSurface(_ leafId: UUID, direction: SplitDirection) {
        let newLeafId = UUID()
        guard let newRoot = splitRoot.inserting(newLeafId: newLeafId, at: leafId, direction: direction) else { return }
        splitRoot = newRoot
        activeSurfaceId = newLeafId
    }

    func closeSurface(_ leafId: UUID) {
        removeCachedSurface(for: leafId)
        guard let newRoot = splitRoot.removing(leafId) else {
            // Last leaf — close entire session
            NotificationCenter.default.post(name: .terminalSessionClosed, object: self)
            onClose?()
            return
        }
        splitRoot = newRoot
        if activeSurfaceId == leafId {
            activeSurfaceId = newRoot.allLeafIds().first
        }
    }

    func updateSplitRatio(firstChildLeafId: UUID, ratio: CGFloat) {
        splitRoot = splitRoot.updatingRatioForSplit(firstChildLeafId: firstChildLeafId, newRatio: ratio)
    }

    deinit {
        gitWatcher?.cancel()
    }

    /// Fallback PWD tracking from terminal title (used when OSC 7 is unavailable).
    func syncState(fromTitle title: String) {
        guard !title.isEmpty else { return }
        self.title = title
        if let pwdFromTitle = parsePwdFromTitle(title) {
            updatePwd(pwdFromTitle)
        }
    }

    /// Update working directory and trigger git branch refresh.
    func updatePwd(_ pwd: String) {
        guard pwd != workingDirectory else { return }
        workingDirectory = pwd
        fileTreeModel.updateRootPath(pwd)
        updateGitBranch()
        watchGitHead()
        onWorkingDirectoryChange?(pwd)
    }

    private static func resolveDirectory(_ path: String?) -> String {
        let fallback = NSHomeDirectory()
        guard let path, !path.isEmpty else { return fallback }

        let expandedPath = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return fallback
        }

        return URL(fileURLWithPath: expandedPath).standardizedFileURL.path
    }

    private func parsePwdFromTitle(_ title: String) -> String? {
        // Common formats: "user@host:~/path", "~/path", "/absolute/path"
        if title.contains(":") {
            let parts = title.components(separatedBy: ":")
            if let path = parts.last, (path.hasPrefix("~") || path.hasPrefix("/")) {
                return path.trimmingCharacters(in: .whitespaces)
            }
        }
        if title.hasPrefix("~") || title.hasPrefix("/") {
            return title.trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    func updateGitBranch() {
        let dir = workingDirectory.replacingOccurrences(of: "~", with: NSHomeDirectory())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
            process.currentDirectoryURL = URL(fileURLWithPath: dir)
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let branch = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DispatchQueue.main.async {
                    self?.gitBranch = (branch?.isEmpty ?? true) ? nil : branch
                }
            } catch {
                DispatchQueue.main.async {
                    self?.gitBranch = nil
                }
            }
        }
    }

    private func watchGitHead() {
        gitWatcher?.cancel()
        gitWatcher = nil

        let dir = workingDirectory.replacingOccurrences(of: "~", with: NSHomeDirectory())
        let gitHeadPath = (dir as NSString).appendingPathComponent(".git/HEAD")

        guard FileManager.default.fileExists(atPath: gitHeadPath) else { return }

        let fd = open(gitHeadPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.updateGitBranch()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        gitWatcher = source
    }
}

// MARK: - MossSurfaceViewDelegate

extension TerminalSession: MossSurfaceViewDelegate {
    func surfaceDidChangeTitle(_ title: String, surface: MossSurfaceView) {
        guard surface.leafId == activeSurfaceId else { return }
        // Reject titles with control characters (uninitialized/garbled data)
        guard !title.isEmpty, title.allSatisfy({ !$0.isASCII || $0.asciiValue! >= 0x20 || $0 == "\t" }) else {
            return
        }
        self.title = title
        // Fallback: try to extract PWD from title when OSC 7 is not available
        if let pwd = parsePwdFromTitle(title) {
            updatePwd(pwd)
        }
    }

    func surfaceDidChangePwd(_ pwd: String, surface: MossSurfaceView) {
        guard surface.leafId == activeSurfaceId else { return }
        print("[Session] surfaceDidChangePwd: \(pwd)")
        // Validate: must be a real path, no control characters
        guard !pwd.isEmpty,
              pwd.hasPrefix("/") || pwd.hasPrefix("~"),
              pwd.allSatisfy({ !$0.isASCII || $0.asciiValue! >= 0x20 })
        else { return }
        updatePwd(pwd)
    }

    func surfaceDidChangeFocus(_ focused: Bool, surface: MossSurfaceView) {
        if focused, let leafId = surface.leafId {
            activeSurfaceId = leafId
            isFocused = true
        } else if !focused {
            // Only unfocus session if no other surface in this session has focus
            // (the new surface's becomeFirstResponder fires after resignFirstResponder)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.activeSurfaceId == surface.leafId {
                    self.isFocused = false
                }
            }
        }
    }

    func surfaceDidRequestDesktopNotification(title: String, body: String) {
        handleDesktopNotification(title: title, body: body)
    }

    func surfaceDidAcknowledgePendingAttention() {
        acknowledgeDesktopNotificationPending()
    }

    func surfaceDidRequestSplit(_ direction: SplitDirection, surface: MossSurfaceView) {
        guard let leafId = surface.leafId else { return }
        splitSurface(leafId, direction: direction)
    }

    func surfaceDidClose(processAlive: Bool, surface: MossSurfaceView) {
        guard let leafId = surface.leafId else { return }
        closeSurface(leafId)
    }

    func surfaceDidRequestStartSearch(needle: String?, surface: MossSurfaceView) {
        if let searchState {
            if let needle, !needle.isEmpty {
                searchState.needle = needle
            }
            searchState.focusToken = UUID()
        } else {
            let state = TerminalSearchState()
            state.needle = needle ?? ""
            state.onNeedleChanged = { [weak self, weak surface] newNeedle in
                guard let surface else { return }
                self?.debouncedSearch(newNeedle, surface: surface)
            }
            searchState = state
        }
    }

    func surfaceDidRequestEndSearch(surface: MossSurfaceView) {
        guard searchState != nil else { return }
        clearSearchState()
        surface.performBindingAction("end_search")
        // Return focus to terminal surface
        surface.window?.makeFirstResponder(surface)
    }

    /// Called from ghostty's GHOSTTY_ACTION_END_SEARCH callback — just clear UI, don't re-send or steal focus.
    func surfaceDidReceiveEndSearch() {
        guard searchState != nil else { return }
        clearSearchState()
    }

    func surfaceDidUpdateSearchTotal(_ total: UInt?) {
        searchState?.total = total
    }

    func surfaceDidUpdateSearchSelected(_ selected: UInt?) {
        searchState?.selected = selected
    }

    // MARK: - Search (public API for views)

    func navigateSearch(_ direction: String) {
        guard let activeSurfaceId else { return }
        let surfaceView = surfaceView(for: activeSurfaceId)
        surfaceView.performBindingAction("navigate_search:\(direction)")
    }

    func endSearch() {
        guard let activeSurfaceId else { return }
        let surfaceView = surfaceView(for: activeSurfaceId)
        surfaceDidRequestEndSearch(surface: surfaceView)
    }

    // MARK: - Search (private)

    private func clearSearchState() {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchState = nil
    }

    private func debouncedSearch(_ needle: String, surface: MossSurfaceView) {
        searchDebounceTask?.cancel()
        if needle.isEmpty || needle.count >= 3 {
            surface.performBindingAction("search:\(needle)")
        } else {
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                surface.performBindingAction("search:\(needle)")
            }
        }
    }
}

extension Notification.Name {
    static let terminalSessionClosed = Notification.Name("terminalSessionClosed")
    static let trackedTasksChanged = Notification.Name("trackedTasksChanged")
}

// MARK: - Search State

@MainActor
@Observable
final class TerminalSearchState {
    var needle: String = "" {
        didSet {
            guard needle != oldValue else { return }
            onNeedleChanged?(needle)
        }
    }
    var selected: UInt?
    var total: UInt?
    /// Changes each time the search field should reclaim focus.
    var focusToken = UUID()

    @ObservationIgnored var onNeedleChanged: ((String) -> Void)?
}
