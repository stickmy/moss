import SwiftUI
import GhosttyKit

struct StableTerminalWrapper: NSViewRepresentable {
    let session: TerminalSession
    let isActive: Bool

    func makeNSView(context: Context) -> MossSurfaceView {
        let view = MossSurfaceView(
            terminalApp: session.terminalApp,
            sessionId: session.id,
            workingDirectory: NSHomeDirectory(),
            socketPath: session.socketPath
        )
        view.delegate = session
        return view
    }

    func updateNSView(_ nsView: MossSurfaceView, context: Context) {
        nsView.isActive = isActive
    }
}
