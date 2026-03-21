import SwiftUI
import GhosttyKit
import AppKit

struct ContentView: View {
    @Bindable var sessionManager: TerminalSessionManager
    @State private var zoomedSession: TerminalSession?
    @State private var showFileTree = false
    @State private var fileTreeSession: TerminalSession?
    @State private var fileTreeWidth: CGFloat = 220
    @State private var previewPanelWidth: CGFloat = 500
    @State private var dragOffsetTree: CGFloat = 0
    @State private var dragOffsetPreview: CGFloat = 0

    private var focusedSession: TerminalSession? {
        sessionManager.sessions.first(where: { $0.isFocused })
    }

    /// Stable session for file tree — updated only when a terminal gains focus.
    private var activeFileTreeSession: TerminalSession? {
        fileTreeSession ?? sessionManager.sessions.first
    }

    var body: some View {
        HStack(spacing: 0) {
            if showFileTree, let session = activeFileTreeSession {
                FileTreeView(model: session.fileTreeModel)
                    .frame(width: fileTreeWidth + dragOffsetTree)

                PaneDivider(
                    onDrag: { delta in
                        dragOffsetTree = max(180 - fileTreeWidth, min(350 - fileTreeWidth, delta))
                    },
                    onDragEnd: {
                        fileTreeWidth = max(180, min(350, fileTreeWidth + dragOffsetTree))
                        dragOffsetTree = 0
                    }
                )

                if session.fileTreeModel.selectedFile != nil {
                    FilePreviewPanel(
                        url: session.fileTreeModel.selectedFile!
                    ) {
                        session.fileTreeModel.selectedFile = nil
                    }
                    .frame(width: previewPanelWidth + dragOffsetPreview)

                    PaneDivider(
                        onDrag: { delta in
                            dragOffsetPreview = max(300 - previewPanelWidth, min(800 - previewPanelWidth, delta))
                        },
                        onDragEnd: {
                            previewPanelWidth = max(300, min(800, previewPanelWidth + dragOffsetPreview))
                            dragOffsetPreview = 0
                        }
                    )
                }
            }

            terminalGrid
        }
        .background(sessionManager.theme.background)
        .environment(\.mossTheme, sessionManager.theme)
        .background(
            ThemedWindowConfigurator(theme: sessionManager.theme)
        )
        .onReceive(NotificationCenter.default.publisher(for: .terminalToggleZoom)) { _ in
            toggleZoom()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalNewRequested)) { _ in
            let s = sessionManager.addSession()
            focusSession(s)
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalToggleFileTree)) { _ in
            showFileTree.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .terminalFocusChanged)) { notif in
            if let id = notif.userInfo?["sessionId"] as? UUID,
               let s = sessionManager.sessions.first(where: { $0.id == id })
            {
                fileTreeSession = s
            }
        }
    }

    // MARK: - Terminal Grid

    private var terminalGrid: some View {
        GeometryReader { geo in
            let sessions = sessionManager.sessions
            let isZoomed = zoomedSession != nil
            let layout = GridLayout(count: sessions.count, size: geo.size)

            ZStack {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    TerminalCell(
                        session: session,
                        isZoomed: zoomedSession?.id == session.id,
                        anyZoomed: isZoomed,
                        sessionCount: sessions.count,
                        frame: zoomedSession?.id == session.id
                            ? CGRect(origin: .zero, size: geo.size)
                            : layout.frame(for: index)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(sessionManager.theme.background)
        .overlay(alignment: .top) {
            if let session = zoomedSession {
                zoomedToolbar(session: session)
            }
        }
        .overlay(alignment: .bottom) {
            if let session = focusedSession {
                TerminalStatusBar(session: session)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: {
                let s = sessionManager.addSession()
                focusSession(s)
            }) {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(sessionManager.theme.secondaryForeground.opacity(0.9))
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .onAppear {
            if let first = sessionManager.sessions.first {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    focusSurfaceView(for: first)
                }
            }
        }
    }

    // MARK: - Focus

    private func focusSession(_ session: TerminalSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focusSurfaceView(for: session)
        }
    }

    private func focusSurfaceView(for session: TerminalSession) {
        guard let window = NSApplication.shared.mainWindow
            ?? NSApplication.shared.keyWindow
        else { return }
        var surfaceViews: [MossSurfaceView] = []
        collectSurfaceViews(in: window.contentView, into: &surfaceViews)
        for view in surfaceViews {
            if view.sessionId == session.id {
                window.makeFirstResponder(view)
                return
            }
        }
    }

    private func collectSurfaceViews(
        in view: NSView?, into result: inout [MossSurfaceView]
    ) {
        guard let view else { return }
        if let sv = view as? MossSurfaceView { result.append(sv); return }
        for sub in view.subviews { collectSurfaceViews(in: sub, into: &result) }
    }

    // MARK: - Zoom

    private func toggleZoom() {
        if zoomedSession != nil {
            zoomedSession = nil
        } else if let session = sessionManager.sessions.first(where: { $0.isFocused }),
                  sessionManager.sessions.count > 1
        {
            zoomedSession = session
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private func zoomedToolbar(session: TerminalSession) -> some View {
        HStack(spacing: 12) {
            Button(action: { zoomedSession = nil }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text(session.title.isEmpty ? "Terminal" : session.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: - Grid Layout

    struct GridLayout {
        let columns: Int
        let rows: Int
        let cellSize: CGSize
        let spacing: CGFloat = 2
        let padding: CGFloat = 2

        init(count: Int, size: CGSize) {
            let cols: Int
            switch count {
            case 0 ... 1: cols = 1
            case 2: cols = 2
            case 3 ... 4: cols = 2
            case 5 ... 6: cols = 3
            case 7 ... 9: cols = 3
            default: cols = 4
            }
            self.columns = cols
            self.rows = max(1, Int(ceil(Double(count) / Double(cols))))
            let totalH = padding * 2 + spacing * CGFloat(max(cols - 1, 0))
            let totalV = padding * 2 + spacing * CGFloat(max(rows - 1, 0))
            self.cellSize = CGSize(
                width: max(100, (size.width - totalH) / CGFloat(cols)),
                height: max(100, (size.height - totalV) / CGFloat(rows))
            )
        }

        func frame(for index: Int) -> CGRect {
            let col = index % columns
            let row = index / columns
            return CGRect(
                x: padding + CGFloat(col) * (cellSize.width + spacing),
                y: padding + CGFloat(row) * (cellSize.height + spacing),
                width: cellSize.width,
                height: cellSize.height
            )
        }
    }
}

// MARK: - TerminalCell

struct TerminalCell: View {
    @Bindable var session: TerminalSession
    let isZoomed: Bool
    let anyZoomed: Bool
    let sessionCount: Int
    let frame: CGRect

    private var visible: Bool { !anyZoomed || isZoomed }

    var body: some View {
        StableTerminalWrapper(session: session, isActive: visible)
            .frame(width: frame.width, height: frame.height)
            .clipped()
            .overlay {
                if visible {
                    StatusBorder(status: session.status)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if visible && !session.isFocused && !anyZoomed && sessionCount > 1 {
                    Color.black.opacity(0.3)
                        .allowsHitTesting(false)
                }
            }
            .position(x: frame.midX, y: frame.midY)
            .opacity(visible ? 1 : 0)
            .zIndex(isZoomed ? 1 : 0)
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
    let onDrag: (_ totalDelta: CGFloat) -> Void
    let onDragEnd: () -> Void
    @Environment(\.mossTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme?.border ?? Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
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
}
