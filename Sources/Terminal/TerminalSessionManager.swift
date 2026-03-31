import Foundation

private struct TaskPayload: Decodable {
    let id: String
    let subject: String?
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case subject
        case sessionId = "session_id"
    }
}

@MainActor
@Observable
final class TerminalSessionManager {
    private(set) var sessions: [TerminalSession] = []
    private let terminalApp: MossTerminalApp
    private let socketServer: SocketServer
    private nonisolated(unsafe) var closeObserver: NSObjectProtocol?
    let canvasStore: TerminalCanvasStore

    var theme: MossTheme { terminalApp.theme }
    var focusedSession: TerminalSession? {
        sessions.first(where: { $0.isFocused })
    }
    var orderedSessions: [TerminalSession] {
        sessions.sorted { lhs, rhs in
            let lhsOrder = canvasStore.item(for: lhs.id)?.createdOrder ?? .max
            let rhsOrder = canvasStore.item(for: rhs.id)?.createdOrder ?? .max
            if lhsOrder == rhsOrder {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhsOrder < rhsOrder
        }
    }

    init(terminalApp: MossTerminalApp, socketServer: SocketServer) {
        self.terminalApp = terminalApp
        self.socketServer = socketServer
        self.canvasStore = TerminalCanvasStore()

        // Wire up IPC commands
        socketServer.onCommand = { [weak self] command in
            self?.handleIPCCommand(command)
                ?? IPCResponse(success: false, message: "No session manager")
        }

        // Observe session close events
        closeObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionClosed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let session = notification.object as? TerminalSession {
                Task { @MainActor [weak self] in
                    self?.removeSession(session)
                }
            }
        }

        restoreSessionsFromSnapshot()
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    @discardableResult
    func addSession(
        layoutHint: TerminalCanvasLayoutHint? = nil,
        launchDirectory: String? = nil
    ) -> TerminalSession {
        let session = makeSession(launchDirectory: launchDirectory)
        let rect = canvasStore.nextRectForNewSession(
            focusedSessionId: focusedSession?.id,
            layoutHint: layoutHint
        )
        canvasStore.registerSession(
            id: session.id,
            rect: rect,
            workingDirectory: session.launchDirectory
        )
        return session
    }

    func removeSession(_ session: TerminalSession) {
        sessions.removeAll { $0.id == session.id }
        canvasStore.removeItem(id: session.id)
    }

    func saveCanvasSnapshot() {
        canvasStore.forceSave()
    }

    private func restoreSessionsFromSnapshot() {
        let restoredItems = canvasStore.items
        if restoredItems.isEmpty {
            if !canvasStore.didLoadPersistentSnapshot {
                addSession()
            }
            return
        }

        for item in restoredItems {
            let session = makeSession(
                id: item.id,
                launchDirectory: item.workingDirectory
            )
            if session.launchDirectory != item.workingDirectory {
                canvasStore.updateWorkingDirectory(
                    id: item.id,
                    workingDirectory: session.launchDirectory
                )
            }
        }
    }

    private func makeSession(
        id: UUID = UUID(),
        launchDirectory: String? = nil
    ) -> TerminalSession {
        let session = TerminalSession(
            id: id,
            terminalApp: terminalApp,
            socketPath: socketServer.socketPath,
            launchDirectory: launchDirectory
        )
        let sessionId = session.id
        session.onWorkingDirectoryChange = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.canvasStore.updateWorkingDirectory(
                    id: sessionId,
                    workingDirectory: path
                )
            }
        }
        sessions.append(session)
        return session
    }

    // MARK: - IPC

    private func handleIPCCommand(_ command: IPCCommand) -> IPCResponse {
        guard let session = sessions.first(where: {
            $0.id.uuidString == command.surfaceId
        }) else {
            return IPCResponse(
                success: false,
                message: "Session not found: \(command.surfaceId)"
            )
        }

        switch command.command {
        case "set_status":
            guard let statusValue = command.value,
                  let status = AgentStatus(rawValue: statusValue)
            else {
                return IPCResponse(success: false, message: "Invalid status value")
            }
            session.setManualStatus(status)
            return IPCResponse(success: true, message: "Status set to \(statusValue)")

        case "set_auto_status":
            guard let statusValue = command.value,
                  let status = AgentStatus(rawValue: statusValue)
            else {
                return IPCResponse(success: false, message: "Invalid status value")
            }
            session.setAutomaticStatus(status)
            return IPCResponse(success: true, message: "Automatic status set to \(status.rawValue)")

        case "get_status":
            return IPCResponse(success: true, message: session.status.rawValue)

        case "agent_session_start":
            guard let sessionId = command.value, !sessionId.isEmpty else {
                return IPCResponse(success: false, message: "Missing session id")
            }
            session.startAgentSession(id: sessionId)
            return IPCResponse(success: true, message: "Agent session started: \(sessionId)")

        case "task_created":
            guard let value = command.value,
                  let data = value.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(TaskPayload.self, from: data),
                  let subject = payload.subject
            else {
                return IPCResponse(success: false, message: "Invalid task payload")
            }
            if let sid = payload.sessionId, !sid.isEmpty,
               session.agentSessionId != nil,
               session.agentSessionId != sid {
                return IPCResponse(success: false, message: "Session mismatch")
            }
            session.addTrackedTask(id: payload.id, subject: subject)
            return IPCResponse(success: true, message: "Task tracked")

        case "task_completed":
            guard let value = command.value,
                  let data = value.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(TaskPayload.self, from: data)
            else {
                return IPCResponse(success: false, message: "Invalid task payload")
            }
            if let sid = payload.sessionId, !sid.isEmpty,
               session.agentSessionId != nil,
               session.agentSessionId != sid {
                return IPCResponse(success: false, message: "Session mismatch")
            }
            session.completeTrackedTask(id: payload.id)
            return IPCResponse(success: true, message: "Task completed")

        case "task_reset":
            session.resetTrackedTasks()
            return IPCResponse(success: true, message: "Tasks reset")

        default:
            return IPCResponse(
                success: false,
                message: "Unknown command: \(command.command)"
            )
        }
    }
}
