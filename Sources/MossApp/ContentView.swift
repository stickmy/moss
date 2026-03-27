import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var sessionManager: TerminalSessionManager
    @State private var showFileTree = false
    @State private var fileTreeSession: TerminalSession?
    @State private var lastFocusedSessionId: UUID?
    @State private var fileTreeWidth: CGFloat = 220
    @State private var dragOffsetTree: CGFloat = 0

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

        return sessionManager.sessions.first
    }

    var body: some View {
        HStack(spacing: 0) {
            if showFileTree, let session = activeFileTreeSession {
                FileTreeView(model: session.fileTreeModel)
                    .frame(width: fileTreeWidth)

                PaneDivider(
                    offset: dragOffsetTree,
                    onDrag: { delta in
                        dragOffsetTree = max(180 - fileTreeWidth, min(350 - fileTreeWidth, delta))
                    },
                    onDragEnd: {
                        fileTreeWidth = max(180, min(350, fileTreeWidth + dragOffsetTree))
                        dragOffsetTree = 0
                    }
                )
            }

            TerminalCanvasView(
                sessionManager: sessionManager,
                appearanceFocusedSessionId: appearanceFocusedSessionId
            )
        }
        .overlay(alignment: .topLeading) {
            if showFileTree,
               let session = activeFileTreeSession,
               let selectedFile = session.fileTreeModel.selectedFile
            {
                FilePreviewPanel(url: selectedFile) {
                    session.fileTreeModel.selectedFile = nil
                }
                .frame(width: 500)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            (sessionManager.theme.border).opacity(0.5),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.35), radius: 24, x: -4, y: 8)
                .padding(.leading, fileTreeWidth + 12)
                .padding(.vertical, 16)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showFileTree ? activeFileTreeSession?.fileTreeModel.selectedFile : nil)
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
    }
}

// MARK: - PaneDivider

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
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = false
            window.isMovableByWindowBackground = false
            window.backgroundColor = NSColor(theme.background)

            if #available(macOS 11.0, *) {
                window.toolbarStyle = .unifiedCompact
            }
        }
    }
}

struct PaneDivider: View {
    private enum Metrics {
        static let visualWidth: CGFloat = 1
        static let interactionWidth: CGFloat = 11
    }

    var offset: CGFloat = 0
    let onDrag: (_ totalDelta: CGFloat) -> Void
    let onDragEnd: () -> Void
    @Environment(\.mossTheme) private var theme
    @State private var isShowingResizeCursor = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(theme?.border ?? Color(nsColor: .separatorColor))
                .frame(width: Metrics.visualWidth)
        }
            .frame(width: Metrics.interactionWidth)
            .contentShape(Rectangle())
            .offset(x: offset)
            .zIndex(10)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    guard !isShowingResizeCursor else { return }
                    NSCursor.resizeLeftRight.push()
                    isShowingResizeCursor = true
                case .ended:
                    releaseResizeCursor()
                }
            }
            .onDisappear {
                releaseResizeCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onDrag(value.translation.width)
                    }
                    .onEnded { _ in
                        onDragEnd()
                    }
            )
    }

    private func releaseResizeCursor() {
        guard isShowingResizeCursor else { return }
        NSCursor.pop()
        isShowingResizeCursor = false
    }
}
