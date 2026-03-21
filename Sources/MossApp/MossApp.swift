import SwiftUI

@main
struct MossApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(sessionManager: appDelegate.sessionManager)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal") {
                    appDelegate.sessionManager.addSession()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
