import Foundation

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
    @ObservationIgnored weak var surfaceView: MossSurfaceView?
    var title: String = ""
    var status: TerminalStatus = .none
    private var manualStatus: TerminalStatus = .none
    private var automaticStatus: TerminalStatus = .none
    private var desktopNotificationPending = false
    var isFocused: Bool = false
    var workingDirectory: String = "~"
    var gitBranch: String?
    var onClose: (() -> Void)?
    var onWorkingDirectoryChange: ((String) -> Void)?
    private nonisolated(unsafe) var gitWatcher: DispatchSourceFileSystemObject?
    var claudeSessionId: String?
    var trackedTasks: [TrackedTask] = []

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
        self.id = id
        self.terminalApp = terminalApp
        self.socketPath = socketPath
        self.launchDirectory = resolvedLaunchDirectory
        self.workingDirectory = resolvedLaunchDirectory
    }

    func setManualStatus(_ status: TerminalStatus) {
        manualStatus = status
        updateDisplayedStatus()
    }

    func setAutomaticStatus(_ status: TerminalStatus) {
        automaticStatus = status
        updateDisplayedStatus()
    }

    private func updateDisplayedStatus() {
        let nextStatus: TerminalStatus

        if manualStatus != .none {
            nextStatus = manualStatus
        } else if desktopNotificationPending {
            nextStatus = .pending
        } else {
            nextStatus = automaticStatus
        }

        guard status != nextStatus else { return }

        status = nextStatus
    }

    // MARK: - Claude Session

    func startClaudeSession(id: String) {
        guard claudeSessionId != id else { return }
        claudeSessionId = id
        resetTrackedTasks()
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
    func surfaceDidChangeTitle(_ title: String) {
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

    func surfaceDidChangePwd(_ pwd: String) {
        print("[Session] surfaceDidChangePwd: \(pwd)")
        // Validate: must be a real path, no control characters
        guard !pwd.isEmpty,
              pwd.hasPrefix("/") || pwd.hasPrefix("~"),
              pwd.allSatisfy({ !$0.isASCII || $0.asciiValue! >= 0x20 })
        else { return }
        updatePwd(pwd)
    }

    func surfaceDidChangeFocus(_ focused: Bool) {
        isFocused = focused
    }

    func surfaceDidRequestDesktopNotification(title: String, body: String) {
        handleDesktopNotification(title: title, body: body)
    }

    func surfaceDidAcknowledgePendingAttention() {
        acknowledgeDesktopNotificationPending()
    }

    func surfaceDidClose(processAlive: Bool) {
        NotificationCenter.default.post(
            name: .terminalSessionClosed,
            object: self
        )
        onClose?()
    }
}

extension Notification.Name {
    static let terminalSessionClosed = Notification.Name("terminalSessionClosed")
    static let trackedTasksChanged = Notification.Name("trackedTasksChanged")
}
