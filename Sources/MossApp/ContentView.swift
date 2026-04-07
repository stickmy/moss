import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var sessionManager: TerminalSessionManager
    @State private var showFileTree = false
    @State private var fileTreeSession: TerminalSession?
    @State private var lastFocusedSessionId: UUID?
    @State private var fileTreeWidth: CGFloat = 220
    @State private var previewPanelWidth: CGFloat = 500
    @State private var showQuickOpen = false

    private var focusedSession: TerminalSession? {
        sessionManager.focusedSession
    }

    private var appearanceFocusedSessionId: UUID? {
        if let focusedId = focusedSession?.id {
            return focusedId
        }

        guard let lastFocusedSessionId,
              sessionManager.sessions.contains(where: { $0.id == lastFocusedSessionId })
        else {
            return nil
        }

        return lastFocusedSessionId
    }

    private var activeFileTreeSession: TerminalSession? {
        if let fileTreeSession,
           sessionManager.sessions.contains(where: { $0.id == fileTreeSession.id })
        {
            return fileTreeSession
        }

        return focusedSession ?? sessionManager.sessions.first
    }

    /// How much of the canvas's left side is covered by the preview panel overlay.
    private var previewPanelOverlap: CGFloat {
        guard showFileTree,
              let session = activeFileTreeSession,
              session.fileTreeModel.selectedFile != nil
        else { return 0 }
        return previewPanelWidth + 1
    }

    private var leftContent: AnyView? {
        guard showFileTree, let session = activeFileTreeSession else { return nil }
        return AnyView(
            FileTreeView(model: session.fileTreeModel)
                .environment(\.mossTheme, sessionManager.theme)
        )
    }

    var body: some View {
        FileTreeSplitContainer(
            leftContent: leftContent,
            rightContent: AnyView(
                TerminalCanvasView(
                    sessionManager: sessionManager,
                    appearanceFocusedSessionId: appearanceFocusedSessionId,
                    overlayLeadingInset: previewPanelOverlap
                )
                .environment(\.mossTheme, sessionManager.theme)
            ),
            dividerPosition: $fileTreeWidth,
            minPosition: 180,
            maxPosition: 350,
            dividerColor: NSColor(sessionManager.theme.border)
        )
        .overlay(alignment: .topLeading) {
            if showFileTree,
               let session = activeFileTreeSession,
               let selectedFile = session.fileTreeModel.selectedFile
            {
                ResizablePanelContainer(
                    content: AnyView(
                        FilePreviewPanel(url: selectedFile) {
                            session.fileTreeModel.selectedFile = nil
                        }
                        .environment(\.mossTheme, sessionManager.theme)
                    ),
                    width: $previewPanelWidth,
                    minWidth: 300,
                    maxWidth: 800,
                    borderColor: NSColor(sessionManager.theme.border)
                )
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
                .padding(.leading, fileTreeWidth + 12)
                .padding(.vertical, 16)
                .transition(.identity)
            }
        }
        // Quick Open overlay
        .overlay {
            if showQuickOpen {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showQuickOpen = false }
            }
        }
        .overlay(alignment: .top) {
            if showQuickOpen, let session = activeFileTreeSession {
                QuickOpenPanel(
                    fileTreeModel: session.fileTreeModel,
                    rootPath: session.fileTreeModel.rootPath,
                    onSelect: { url in
                        showQuickOpen = false
                        if !showFileTree { showFileTree = true }
                        session.fileTreeModel.selectedFile = url
                    },
                    onDismiss: {
                        showQuickOpen = false
                    }
                )
                .frame(width: 600)
                .padding(.top, 48)
            }
        }
        .animation(nil, value: showQuickOpen)
        .animation(nil, value: showFileTree ? activeFileTreeSession?.fileTreeModel.selectedFile : nil)
        .background(sessionManager.theme.background)
        .environment(\.mossTheme, sessionManager.theme)
        .background(
            ThemedWindowConfigurator(theme: sessionManager.theme)
        )
        .onReceive(NotificationCenter.default.publisher(for: .terminalToggleFileTree)) { _ in
            showFileTree.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalFocusChanged)) { notif in
            if let id = notif.userInfo?["sessionId"] as? UUID,
               let session = sessionManager.sessions.first(where: { $0.id == id })
            {
                lastFocusedSessionId = id
                fileTreeSession = session
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickOpenRequested)) { _ in
            showQuickOpen = true
        }
    }
}

// MARK: - Window Configurator

private struct ThemedWindowConfigurator: NSViewRepresentable {
    let theme: MossTheme

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        applyConfiguration(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyConfiguration(from: nsView)
    }

    private func applyConfiguration(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }

            let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            NSApp.appearance = appearance
            window.appearance = appearance

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(theme.background)

            NSLog("[ThemedWindowConfigurator] isDark=%d bg=(%@)", theme.isDark, window.backgroundColor?.description ?? "nil")
        }
    }
}
