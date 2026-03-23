import Foundation

@MainActor
@Observable
final class TerminalSessionManager {
    private(set) var sessions: [TerminalSession] = []
    private let terminalApp: MossTerminalApp
    private let socketServer: SocketServer
    private nonisolated(unsafe) var closeObserver: NSObjectProtocol?

    var theme: MossTheme { terminalApp.theme }

    init(terminalApp: MossTerminalApp, socketServer: SocketServer) {
        self.terminalApp = terminalApp
        self.socketServer = socketServer

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
                self?.sessions.removeAll { $0.id == session.id }
            }
        }

        // Add initial terminal
        addSession()
    }

    deinit {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
    }

    @discardableResult
    func addSession() -> TerminalSession {
        let session = TerminalSession(
            terminalApp: terminalApp,
            socketPath: socketServer.socketPath
        )
        sessions.append(session)
        return session
    }

    func removeSession(_ session: TerminalSession) {
        sessions.removeAll { $0.id == session.id }
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
                  let status = TerminalStatus(rawValue: statusValue)
            else {
                return IPCResponse(success: false, message: "Invalid status value")
            }
            session.setManualStatus(status)
            return IPCResponse(success: true, message: "Status set to \(statusValue)")

        case "set_auto_status":
            guard let statusValue = command.value else {
                return IPCResponse(success: false, message: "Invalid status value")
            }
            let normalizedStatus = (statusValue == "running")
                ? TerminalStatus.none
                : TerminalStatus(rawValue: statusValue)
            guard let normalizedStatus else {
                return IPCResponse(success: false, message: "Invalid status value")
            }
            session.setAutomaticStatus(normalizedStatus)
            return IPCResponse(success: true, message: "Automatic status set to \(normalizedStatus.rawValue)")

        case "get_status":
            return IPCResponse(success: true, message: session.status.rawValue)

        default:
            return IPCResponse(
                success: false,
                message: "Unknown command: \(command.command)"
            )
        }
    }
}
