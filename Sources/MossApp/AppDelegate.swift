import AppKit
import GhosttyKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let socketServer: SocketServer
    let sessionManager: TerminalSessionManager

    override init() {
        let server = SocketServer()
        server.start()
        self.socketServer = server

        let terminalApp = MossTerminalApp()
        self.sessionManager = TerminalSessionManager(
            terminalApp: terminalApp, socketServer: server
        )

        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {}

    func applicationWillTerminate(_: Notification) {
        sessionManager.saveCanvasSnapshot()
        socketServer.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
}
