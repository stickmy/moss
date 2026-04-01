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
    
    func applicationDidFinishLaunching(_: Notification) {
        AgentNotificationManager.shared.requestPermission()
        installCLI()
    }
    
    func applicationWillTerminate(_: Notification) {
        sessionManager.saveCanvasSnapshot()
        socketServer.stop()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { true }
    
    // MARK: - CLI Installation

    /// Symlinks the bundled `moss` CLI to `~/.local/bin/moss` so it's available
    /// outside of Moss terminals (e.g. Claude Code hooks, other terminal apps).
    /// Inside Moss terminals, the CLI is already available via shell integration alias.
    private func installCLI() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let bundledCLI = resourceURL.appendingPathComponent("moss")
        guard FileManager.default.isExecutableFile(atPath: bundledCLI.path) else { return }

        let installDir = NSHomeDirectory() + "/.local/bin"
        let installPath = "\(installDir)/moss"
        let fm = FileManager.default

        if let dest = try? fm.destinationOfSymbolicLink(atPath: installPath),
           dest == bundledCLI.path
        {
            return
        }

        if !fm.fileExists(atPath: installDir) {
            try? fm.createDirectory(atPath: installDir, withIntermediateDirectories: true)
        }

        try? fm.removeItem(atPath: installPath)

        do {
            try fm.createSymbolicLink(atPath: installPath, withDestinationPath: bundledCLI.path)
        } catch {
            NSLog("Moss: failed to install CLI to \(installPath): \(error)")
        }
    }
}
