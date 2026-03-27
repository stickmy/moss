import SwiftUI
import GhosttyKit

struct StableTerminalWrapper: NSViewRepresentable {
    let session: TerminalSession
    let isActive: Bool

    func makeNSView(context: Context) -> MossSurfaceView {
        let view = MossSurfaceView(
            terminalApp: session.terminalApp,
            sessionId: session.id,
            workingDirectory: session.launchDirectory,
            socketPath: session.socketPath
        )
        view.delegate = session
        session.surfaceView = view
        return view
    }

    func updateNSView(_ nsView: MossSurfaceView, context: Context) {
        if session.surfaceView !== nsView {
            session.surfaceView = nsView
        }
        nsView.isActive = isActive
        nsView.isHidden = !isActive
    }

    static func dismantleNSView(_ nsView: MossSurfaceView, coordinator: ()) {
        if let session = nsView.delegate as? TerminalSession,
           session.surfaceView === nsView
        {
            session.surfaceView = nil
        }
    }
}
