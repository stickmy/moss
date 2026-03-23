import SwiftUI
import GhosttyKit
import AppKit

struct ContentView: View {
    @Bindable var sessionManager: TerminalSessionManager
    @State private var zoomedSession: TerminalSession?
    @State private var showFileTree = false
    @State private var fileTreeSession: TerminalSession?
    @State private var lastFocusedSessionId: UUID?
    @State private var fileTreeWidth: CGFloat = 220
    @State private var previewPanelWidth: CGFloat = 500
    @State private var dragOffsetTree: CGFloat = 0
    @State private var dragOffsetPreview: CGFloat = 0

    private var focusedSession: TerminalSession? {
        sessionManager.sessions.first(where: { $0.isFocused })
    }

    /// Stable focus fallback used for appearance while focus is temporarily nil.
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

    /// Stable session for file tree — updated only when a terminal gains focus.
    private var activeFileTreeSession: TerminalSession? {
        fileTreeSession ?? sessionManager.sessions.first
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

                if session.fileTreeModel.selectedFile != nil {
                    FilePreviewPanel(
                        url: session.fileTreeModel.selectedFile!
                    ) {
                        session.fileTreeModel.selectedFile = nil
                    }
                    .frame(width: previewPanelWidth)

                    PaneDivider(
                        offset: dragOffsetPreview,
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
                lastFocusedSessionId = id
                fileTreeSession = s
            }
        }
    }

    // MARK: - Terminal Grid

    private var terminalGrid: some View {
        GeometryReader { geo in
            let sessions = sessionManager.sessions
            let isZoomed = zoomedSession != nil
            let appearanceFocusedSessionId = appearanceFocusedSessionId
            let layout = GridLayout(count: sessions.count, size: geo.size)

            ZStack {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    TerminalCell(
                        session: session,
                        appearanceFocusedSessionId: appearanceFocusedSessionId,
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
        let count: Int
        let columns: Int
        let rows: Int
        let size: CGSize
        let spacing: CGFloat = 2
        let padding: CGFloat = 2

        init(count: Int, size: CGSize) {
            self.count = count
            self.size = size
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
        }

        private func itemCount(inRow row: Int) -> Int {
            guard row >= 0, row < rows else { return 0 }
            guard row == rows - 1 else { return columns }

            let remainder = count % columns
            return remainder == 0 ? columns : remainder
        }

        private var rowHeight: CGFloat {
            let totalV = padding * 2 + spacing * CGFloat(max(rows - 1, 0))
            return max(100, (size.height - totalV) / CGFloat(rows))
        }

        func frame(for index: Int) -> CGRect {
            let row = max(0, min(rows - 1, index / columns))
            let col = index % columns
            let itemsInRow = max(1, itemCount(inRow: row))
            let totalH = padding * 2 + spacing * CGFloat(max(itemsInRow - 1, 0))
            let cellWidth = max(100, (size.width - totalH) / CGFloat(itemsInRow))

            return CGRect(
                x: padding + CGFloat(col) * (cellWidth + spacing),
                y: padding + CGFloat(row) * (rowHeight + spacing),
                width: cellWidth,
                height: rowHeight
            )
        }
    }
}

// MARK: - TerminalCell

struct TerminalCell: View {
    @Bindable var session: TerminalSession
    @Environment(\.mossTheme) private var theme
    let appearanceFocusedSessionId: UUID?
    let isZoomed: Bool
    let anyZoomed: Bool
    let sessionCount: Int
    let frame: CGRect

    private var visible: Bool { !anyZoomed || isZoomed }
    private var isAppearanceFocused: Bool {
        session.isFocused || appearanceFocusedSessionId == session.id
    }

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
                if visible && !isAppearanceFocused && !anyZoomed && sessionCount > 1,
                   let theme,
                   theme.unfocusedSplitOpacity > 0
                {
                    Rectangle()
                        .fill(theme.unfocusedSplitFill)
                        .allowsHitTesting(false)
                        .opacity(theme.unfocusedSplitOpacity)
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
