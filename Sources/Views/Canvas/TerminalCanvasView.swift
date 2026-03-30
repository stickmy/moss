import AppKit
import SwiftUI

private final class CanvasHoverRef {
    var isHovered = false
}

struct TerminalCanvasView: View {
    @Bindable var sessionManager: TerminalSessionManager
    let appearanceFocusedSessionId: UUID?

    @State private var canvasSize: CGSize = .zero
    @State private var panStartOffset: CGPoint?
    @State private var zoomStartScale: CGFloat?
    @State private var interactingSessionId: UUID?
    @State private var hasRequestedInitialFocus = false
    @State private var scrollMonitor: Any?
    @State private var magnifyMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var canvasHover = CanvasHoverRef()

    private var canvasStore: TerminalCanvasStore { sessionManager.canvasStore }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                TerminalCanvasGridBackground(
                    viewport: canvasStore.viewport,
                    size: size
                )
                .contentShape(Rectangle())
                .gesture(canvasPanGesture)
                .simultaneousGesture(canvasMagnificationGesture)

                if sessionManager.orderedSessions.isEmpty {
                    emptyState
                }

                ForEach(sessionManager.orderedSessions) { session in
                    if let item = canvasStore.item(for: session.id) {
                        TerminalCanvasCard(
                            session: session,
                            logicalRect: item.rect,
                            screenRect: screenRect(for: item.rect, in: size),
                            scale: canvasStore.viewport.scale,
                            isAppearanceFocused: session.isFocused || appearanceFocusedSessionId == session.id,
                            isInteracting: interactingSessionId == session.id,
                            onFocus: { focusSession(session) },
                            onFit: { fitViewport(to: session) },
                            onClose: { sessionManager.removeSession(session) },
                            onInteractionChanged: { isInteracting in
                                interactingSessionId = isInteracting ? session.id : nil
                            },
                            resolveMove: { originalRect, translation in
                                canvasStore.resolvedMoveRect(
                                    for: session.id,
                                    originalRect: originalRect,
                                    translation: translation
                                )
                            },
                            commitMove: { rect in
                                canvasStore.updateRect(
                                    id: session.id,
                                    rect: rect
                                )
                            },
                            onResize: { handle, originalRect, translation in
                                canvasStore.updateRect(
                                    id: session.id,
                                    rect: canvasStore.resolvedResizeRect(
                                        for: session.id,
                                        originalRect: originalRect,
                                        handle: handle,
                                        translation: translation
                                    )
                                )
                            }
                        )
                        .zIndex(zIndex(for: session, item: item))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .contentShape(Rectangle())
            .onHover { canvasHover.isHovered = $0 }
            .background(sessionManager.theme.background)
            .overlay(alignment: .topLeading) {
                canvasControls
                    .padding(12)
            }
            .onAppear {
                canvasSize = size
                requestInitialFocusIfNeeded()
                installScrollMonitor()
                installMagnifyMonitor()
                installKeyMonitor()
            }
            .onDisappear {
                removeScrollMonitor()
                removeMagnifyMonitor()
                removeKeyMonitor()
            }
            .onChange(of: size) { _, newValue in
                canvasSize = newValue
                requestInitialFocusIfNeeded()
                refitViewportIfNeeded(in: newValue)
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalNewRequested)) { _ in
                createNewSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalToggleZoom)) { _ in
                fitFocusedSession()
            }
        }
    }

    private var canvasPanGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if panStartOffset == nil {
                    panStartOffset = canvasStore.viewport.offset
                }

                guard let panStartOffset else { return }
                let delta = CGSize(
                    width: value.translation.width / max(canvasStore.viewport.scale, 0.1),
                    height: value.translation.height / max(canvasStore.viewport.scale, 0.1)
                )

                var viewport = canvasStore.viewport
                viewport.offset = CGPoint(
                    x: panStartOffset.x - delta.width,
                    y: panStartOffset.y - delta.height
                )
                viewport.fittedSessionId = nil
                canvasStore.setViewport(viewport)
            }
            .onEnded { _ in
                panStartOffset = nil
            }
    }

    private var canvasMagnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if zoomStartScale == nil {
                    zoomStartScale = canvasStore.viewport.scale
                }

                guard let zoomStartScale else { return }
                let newScale = zoomStartScale * value
                setScale(newScale)
            }
            .onEnded { _ in
                zoomStartScale = nil
            }
    }

    private var canvasControls: some View {
        HStack(spacing: 10) {
            Text("\(Int(canvasStore.viewport.scale * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(sessionManager.theme.secondaryForeground)

            Button(action: { zoom(by: 0.9) }) {
                Image(systemName: "minus")
            }
            .buttonStyle(.plain)

            Button(action: { zoom(by: 1.1) }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)

            Button("Reset") {
                canvasStore.resetViewport()
            }
            .buttonStyle(.plain)

            Button("Fit") {
                fitFocusedSession()
            }
            .buttonStyle(.plain)
            .disabled(currentFocusTarget == nil)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(sessionManager.theme.border.opacity(0.55), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.dashed")
                .font(.title2)
                .foregroundStyle(sessionManager.theme.secondaryForeground)

            Text("Canvas is empty")
                .font(.headline)
                .foregroundStyle(sessionManager.theme.foreground)

            Text("Create a terminal and place it anywhere.")
                .font(.caption)
                .foregroundStyle(sessionManager.theme.secondaryForeground)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(sessionManager.theme.surfaceBackground.opacity(0.9))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(sessionManager.theme.border.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
        }
    }

    private var currentFocusTarget: TerminalSession? {
        sessionManager.focusedSession
            ?? sessionManager.orderedSessions.first(where: { $0.id == appearanceFocusedSessionId })
            ?? sessionManager.orderedSessions.first
    }

    private func createNewSession() {
        let session = sessionManager.addSession()
        focusSession(session)
    }

    private func fitFocusedSession() {
        guard let target = currentFocusTarget else { return }
        fitViewport(to: target)
    }

    private func fitViewport(to session: TerminalSession) {
        canvasStore.fitViewport(to: session.id, in: canvasSize)
    }

    private func focusSession(_ session: TerminalSession) {
        SurfaceFocusCoordinator.focus(session)
    }

    private func requestInitialFocusIfNeeded() {
        guard !hasRequestedInitialFocus,
              let session = sessionManager.orderedSessions.first
        else { return }

        hasRequestedInitialFocus = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            focusSession(session)
        }
    }

    private func refitViewportIfNeeded(in newSize: CGSize) {
        guard let target = currentFocusTarget,
              let item = canvasStore.item(for: target.id)
        else { return }

        let scale = max(canvasStore.viewport.scale, 0.1)
        let halfW = newSize.width / (2 * scale)
        let halfH = newSize.height / (2 * scale)

        var offset = canvasStore.viewport.offset
        var changed = false

        // Clamp offset.x so the focused terminal stays fully visible
        let minOffsetX = item.rect.maxX - halfW
        let maxOffsetX = item.rect.minX + halfW
        if minOffsetX > maxOffsetX {
            // Terminal wider than canvas — center on it
            offset.x = item.rect.midX
            changed = true
        } else {
            let clamped = max(minOffsetX, min(maxOffsetX, offset.x))
            if clamped != offset.x { offset.x = clamped; changed = true }
        }

        let minOffsetY = item.rect.maxY - halfH
        let maxOffsetY = item.rect.minY + halfH
        if minOffsetY > maxOffsetY {
            offset.y = item.rect.midY
            changed = true
        } else {
            let clamped = max(minOffsetY, min(maxOffsetY, offset.y))
            if clamped != offset.y { offset.y = clamped; changed = true }
        }

        if changed {
            var viewport = canvasStore.viewport
            viewport.offset = offset
            canvasStore.setViewport(viewport)
        }
    }

    private func zoom(by factor: CGFloat) {
        setScale(canvasStore.viewport.scale * factor)
    }

    private func setScale(_ scale: CGFloat) {
        var viewport = canvasStore.viewport
        viewport.scale = min(TerminalCanvasMetrics.maxScale, max(TerminalCanvasMetrics.minScale, scale))
        viewport.fittedSessionId = nil
        canvasStore.setViewport(viewport)
    }

    private func zIndex(
        for session: TerminalSession,
        item: TerminalCanvasItemSnapshot
    ) -> Double {
        if interactingSessionId == session.id {
            return 10_000
        }
        if session.isFocused || appearanceFocusedSessionId == session.id {
            return 5_000 + Double(item.createdOrder)
        }
        return Double(item.createdOrder)
    }

    private func screenRect(
        for logicalRect: CGRect,
        in size: CGSize
    ) -> CGRect {
        let scale = canvasStore.viewport.scale
        let origin = CGPoint(
            x: (logicalRect.minX - canvasStore.viewport.offset.x) * scale + size.width / 2,
            y: (logicalRect.minY - canvasStore.viewport.offset.y) * scale + size.height / 2
        )
        return CGRect(
            x: origin.x,
            y: origin.y,
            width: logicalRect.width * scale,
            height: logicalRect.height * scale
        )
    }

    // MARK: - Scroll Monitor

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let store = canvasStore
        let hover = canvasHover
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hover.isHovered else { return event }
            guard let window = event.window else { return event }

            // Cmd+scroll = zoom canvas
            if event.modifierFlags.contains(.command) {
                let dy = event.scrollingDeltaY
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.03
                let factor = 1 + dy * sensitivity
                var viewport = store.viewport
                viewport.scale = min(
                    TerminalCanvasMetrics.maxScale,
                    max(TerminalCanvasMetrics.minScale, viewport.scale * factor)
                )
                viewport.fittedSessionId = nil
                store.setViewport(viewport)
                return nil
            }

            // Let the focused terminal handle its own scrollback
            if let focused = window.firstResponder as? MossSurfaceView {
                let point = focused.convert(event.locationInWindow, from: nil)
                if focused.bounds.contains(point) {
                    return event
                }
            }

            // Let any enclosing scroll view handle its own scroll
            if let contentView = window.contentView {
                let windowPoint = contentView.convert(event.locationInWindow, from: nil)
                if let hitView = contentView.hitTest(windowPoint),
                   hitView.enclosingScrollView != nil
                {
                    return event
                }
            }

            // Pan the canvas
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                dx *= 20
                dy *= 20
            }
            let scale = max(store.viewport.scale, 0.1)
            var viewport = store.viewport
            viewport.offset.x -= dx / scale
            viewport.offset.y -= dy / scale
            viewport.fittedSessionId = nil
            store.setViewport(viewport)

            return nil
        }
    }

    private func removeScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }

    // MARK: - Magnify Monitor

    private func installMagnifyMonitor() {
        guard magnifyMonitor == nil else { return }
        let store = canvasStore
        let hover = canvasHover
        magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
            guard hover.isHovered else { return event }

            var viewport = store.viewport
            let newScale = viewport.scale * (1 + event.magnification)
            viewport.scale = min(
                TerminalCanvasMetrics.maxScale,
                max(TerminalCanvasMetrics.minScale, newScale)
            )
            viewport.fittedSessionId = nil
            store.setViewport(viewport)

            return nil
        }
    }

    private func removeMagnifyMonitor() {
        if let monitor = magnifyMonitor {
            NSEvent.removeMonitor(monitor)
            magnifyMonitor = nil
        }
    }

    // MARK: - Key Monitor

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let store = canvasStore
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            guard mods == .command else { return event }

            switch event.charactersIgnoringModifiers {
            case "=", "+":
                var viewport = store.viewport
                viewport.scale = min(
                    TerminalCanvasMetrics.maxScale,
                    max(TerminalCanvasMetrics.minScale, viewport.scale * 1.1)
                )
                viewport.fittedSessionId = nil
                store.setViewport(viewport)
                return nil
            case "-":
                var viewport = store.viewport
                viewport.scale = min(
                    TerminalCanvasMetrics.maxScale,
                    max(TerminalCanvasMetrics.minScale, viewport.scale / 1.1)
                )
                viewport.fittedSessionId = nil
                store.setViewport(viewport)
                return nil
            case "0":
                store.resetViewport()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }
}

private struct TerminalCanvasCard: View {
    private let showLayoutDebug = false
    private let cardCornerRadius: CGFloat = 2

    @Bindable var session: TerminalSession
    let logicalRect: CGRect
    let screenRect: CGRect
    let scale: CGFloat
    let isAppearanceFocused: Bool
    let isInteracting: Bool
    let onFocus: () -> Void
    let onFit: () -> Void
    let onClose: () -> Void
    let onInteractionChanged: (Bool) -> Void
    let resolveMove: (_ originalRect: CGRect, _ translation: CGSize) -> CGRect
    let commitMove: (_ rect: CGRect) -> Void
    let onResize: (_ handle: TerminalCanvasResizeHandle, _ originalRect: CGRect, _ translation: CGSize) -> Void

    @Environment(\.mossTheme) private var theme

    private var headerHeight: CGFloat {
        max(44, 48 * scale)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        cardSurface(showFitButton: true) {
            StableTerminalWrapper(session: session, isActive: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: screenRect.width, height: screenRect.height)
        .overlay {
            resizeHandles
        }
        .shadow(color: .black.opacity(isInteracting ? 0.22 : 0.12), radius: isInteracting ? 18 : 10, y: 8)
        .position(x: screenRect.midX, y: screenRect.midY)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var borderColor: Color {
        if isAppearanceFocused {
            return theme?.border.opacity(0.5) ?? .white.opacity(0.15)
        }
        return theme?.border.opacity(0.75) ?? .white.opacity(0.2)
    }

    private var accentColor: Color {
        theme?.foreground.opacity(0.6) ?? .white.opacity(0.6)
    }

    @ViewBuilder
    private func cardSurface<Content: View>(
        showFitButton: Bool,
        @ViewBuilder terminalContent: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            header(showFitButton: showFitButton)
                .frame(height: headerHeight)

            accentColor
                .frame(height: 2)
                .opacity(isAppearanceFocused ? 1 : 0)

            terminalContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: screenRect.width, height: screenRect.height)
        .background(theme?.surfaceBackground.opacity(0.96) ?? Color(nsColor: .windowBackgroundColor))
        .clipShape(cardShape)
        .overlay {
            cardShape
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .overlay {
            StatusBorder(status: session.status)
                .clipShape(cardShape)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func header(showFitButton: Bool) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if showFitButton {
                    nativeDragHandle
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(session.status == .pending ? Color.orange : (theme?.secondaryForeground ?? .secondary).opacity(0.7))
                        .frame(width: 8, height: 8)

                    if !session.trackedTasks.isEmpty {
                        TaskProgressIndicator(tasks: session.trackedTasks)
                    }

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showFitButton {
                CardHeaderButton(systemImage: "viewfinder", color: theme?.secondaryForeground ?? .secondary, action: onFit)
                CardHeaderButton(systemImage: "xmark", color: theme?.secondaryForeground ?? .secondary, action: onClose)
            } else {
                Image(systemName: "viewfinder")
                    .font(.caption)
                    .foregroundStyle((theme?.secondaryForeground ?? .secondary).opacity(0.55))

                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle((theme?.secondaryForeground ?? .secondary).opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(theme?.background.mix(with: .white, by: 0.04) ?? Color.black.opacity(0.2))
        )
        .overlay {
            if showLayoutDebug {
                Rectangle()
                    .stroke(Color.yellow, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var nativeDragHandle: some View {
        TerminalCanvasNativeHeaderDragHandle(
            logicalRect: logicalRect,
            screenRect: screenRect,
            scale: scale,
            headerHeight: headerHeight,
            onFocus: onFocus,
            onInteractionChanged: onInteractionChanged,
            resolveMove: resolveMove,
            commitMove: commitMove
        )
    }

    @ViewBuilder
    private var resizeHandles: some View {
        ZStack {
            ForEach(interactiveResizeHandles, id: \.self) { handle in
                TerminalCanvasResizeHandleView(
                    handle: handle,
                    screenRect: screenRect,
                    scale: scale,
                    logicalRect: logicalRect,
                    headerHeight: headerHeight,
                    showDebugLayout: showLayoutDebug,
                    onFocus: onFocus,
                    onInteractionChanged: onInteractionChanged,
                    onResize: onResize
                )
            }
        }
    }

    private var interactiveResizeHandles: [TerminalCanvasResizeHandle] {
        TerminalCanvasResizeHandle.allCases.filter { $0 != .north }
    }

    private func logicalTranslation(for translation: CGSize) -> CGSize {
        CGSize(
            width: translation.width / max(scale, 0.1),
            height: translation.height / max(scale, 0.1)
        )
    }

}

private struct TerminalCanvasResizeHandleView: View {
    private enum Metrics {
        static let cornerSize: CGFloat = 16
        static let edgeThickness: CGFloat = 6
        static let edgeInsetFromCorner: CGFloat = 20
        static let outsideOffset: CGFloat = 3
    }

    let handle: TerminalCanvasResizeHandle
    let screenRect: CGRect
    let scale: CGFloat
    let logicalRect: CGRect
    let headerHeight: CGFloat
    let showDebugLayout: Bool
    let onFocus: () -> Void
    let onInteractionChanged: (Bool) -> Void
    let onResize: (_ handle: TerminalCanvasResizeHandle, _ originalRect: CGRect, _ translation: CGSize) -> Void

    @State private var resizeStartRect: CGRect?

    var body: some View {
        Rectangle()
            .fill(debugColor.opacity(showDebugLayout ? 0.18 : 0.001))
            .frame(width: handleFrame.width, height: handleFrame.height)
            .contentShape(Rectangle())
            .overlay {
                if showDebugLayout {
                    Rectangle()
                        .stroke(debugColor, lineWidth: 1)
                }
            }
            .onHover { hovering in
                if hovering {
                    handleCursor.push()
                } else if resizeStartRect == nil {
                    NSCursor.pop()
                }
            }
            .gesture(resizeGesture)
            .offset(x: handleFrame.minX, y: handleFrame.minY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if resizeStartRect == nil {
                    resizeStartRect = logicalRect
                    onInteractionChanged(true)
                    onFocus()
                }
                guard let resizeStartRect else { return }
                let translation = CGSize(
                    width: value.translation.width / max(scale, 0.1),
                    height: value.translation.height / max(scale, 0.1)
                )
                onResize(handle, resizeStartRect, translation)
            }
            .onEnded { _ in
                resizeStartRect = nil
                onInteractionChanged(false)
                NSCursor.pop()
            }
    }

    private var debugColor: Color {
        switch handle {
        case .north:
            return .red
        case .south:
            return .orange
        case .east:
            return .green
        case .west:
            return .blue
        case .northEast, .northWest, .southEast, .southWest:
            return .purple
        }
    }

    private var handleCursor: NSCursor {
        switch handle {
        case .north, .south:
            return .resizeUpDown
        case .east, .west:
            return .resizeLeftRight
        case .northEast, .southWest:
            return Self.diagonalNESWCursor
        case .northWest, .southEast:
            return Self.diagonalNWSECursor
        }
    }

    private static let diagonalNESWCursor: NSCursor = {
        if let cursor = cursorFromPrivateSelector("_windowResizeNorthEastSouthWestCursor") {
            return cursor
        }
        return .crosshair
    }()

    private static let diagonalNWSECursor: NSCursor = {
        if let cursor = cursorFromPrivateSelector("_windowResizeNorthWestSouthEastCursor") {
            return cursor
        }
        return .crosshair
    }()

    private static func cursorFromPrivateSelector(_ name: String) -> NSCursor? {
        let sel = NSSelectorFromString(name)
        guard NSCursor.responds(to: sel),
              let result = NSCursor.perform(sel)
        else { return nil }
        return result.takeUnretainedValue() as? NSCursor
    }

    private var handleFrame: CGRect {
        let cardWidth = screenRect.width
        let cardHeight = screenRect.height
        let innerWidth = max(20, cardWidth - Metrics.edgeInsetFromCorner * 2)
        let topInsetForSides = max(headerHeight, Metrics.edgeInsetFromCorner)
        let innerHeight = max(20, cardHeight - topInsetForSides - Metrics.edgeInsetFromCorner)

        switch handle {
        case .north:
            return CGRect(
                x: (cardWidth - innerWidth) / 2,
                y: -Metrics.outsideOffset,
                width: innerWidth,
                height: Metrics.edgeThickness
            )
        case .south:
            return CGRect(
                x: (cardWidth - innerWidth) / 2,
                y: cardHeight - Metrics.edgeThickness + Metrics.outsideOffset,
                width: innerWidth,
                height: Metrics.edgeThickness
            )
        case .east:
            return CGRect(
                x: cardWidth - Metrics.edgeThickness + Metrics.outsideOffset,
                y: topInsetForSides,
                width: Metrics.edgeThickness,
                height: innerHeight
            )
        case .west:
            return CGRect(
                x: -Metrics.outsideOffset,
                y: topInsetForSides,
                width: Metrics.edgeThickness,
                height: innerHeight
            )
        case .northEast:
            return CGRect(
                x: cardWidth - Metrics.cornerSize + Metrics.outsideOffset,
                y: -Metrics.outsideOffset,
                width: Metrics.cornerSize,
                height: Metrics.cornerSize
            )
        case .northWest:
            return CGRect(
                x: -Metrics.outsideOffset,
                y: -Metrics.outsideOffset,
                width: Metrics.cornerSize,
                height: Metrics.cornerSize
            )
        case .southEast:
            return CGRect(
                x: cardWidth - Metrics.cornerSize + Metrics.outsideOffset,
                y: cardHeight - Metrics.cornerSize + Metrics.outsideOffset,
                width: Metrics.cornerSize,
                height: Metrics.cornerSize
            )
        case .southWest:
            return CGRect(
                x: -Metrics.outsideOffset,
                y: cardHeight - Metrics.cornerSize + Metrics.outsideOffset,
                width: Metrics.cornerSize,
                height: Metrics.cornerSize
            )
        }
    }
}

private struct TerminalCanvasNativeHeaderDragHandle: NSViewRepresentable {
    let logicalRect: CGRect
    let screenRect: CGRect
    let scale: CGFloat
    let headerHeight: CGFloat
    let onFocus: () -> Void
    let onInteractionChanged: (Bool) -> Void
    let resolveMove: (_ originalRect: CGRect, _ translation: CGSize) -> CGRect
    let commitMove: (_ rect: CGRect) -> Void

    func makeNSView(context: Context) -> TerminalCanvasNativeHeaderDragView {
        let view = TerminalCanvasNativeHeaderDragView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: TerminalCanvasNativeHeaderDragView, context: Context) {
        update(nsView)
    }

    private func update(_ view: TerminalCanvasNativeHeaderDragView) {
        view.logicalRect = logicalRect
        view.cardSize = screenRect.size
        view.scale = scale
        view.headerHeight = headerHeight
        view.onFocus = onFocus
        view.onInteractionChanged = onInteractionChanged
        view.resolveMove = resolveMove
        view.commitMove = commitMove
    }
}

@MainActor
private final class TerminalCanvasNativeHeaderDragView: NSView {
    var logicalRect: CGRect = .zero
    var cardSize: CGSize = .zero
    var scale: CGFloat = 1
    var headerHeight: CGFloat = 0
    var onFocus: (() -> Void)?
    var onInteractionChanged: ((Bool) -> Void)?
    var resolveMove: ((_ originalRect: CGRect, _ translation: CGSize) -> CGRect)?
    var commitMove: ((_ rect: CGRect) -> Void)?

    private var dragStartPoint: NSPoint?
    private var dragStartRect: CGRect?
    private var isDragging = false

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStartPoint = event.locationInWindow
        dragStartRect = logicalRect
        onFocus?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartPoint, let dragStartRect else { return }

        if !isDragging {
            isDragging = true
            onInteractionChanged?(true)
            window?.invalidateCursorRects(for: self)
        }

        let current = event.locationInWindow
        let logicalTranslation = CGSize(
            width: (current.x - dragStartPoint.x) / max(scale, 0.1),
            height: -(current.y - dragStartPoint.y) / max(scale, 0.1)
        )
        let resolvedRect = resolveMove?(dragStartRect, logicalTranslation) ?? dragStartRect
        commitMove?(resolvedRect)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onInteractionChanged?(false)
            DispatchQueue.main.async { [onFocus] in
                onFocus?()
            }
        }

        isDragging = false
        dragStartPoint = nil
        dragStartRect = nil
        window?.invalidateCursorRects(for: self)
    }

    override func mouseExited(with event: NSEvent) {
        discardCursorRects()
    }
}

private struct TerminalCanvasGridBackground: View {
    let viewport: TerminalCanvasViewport
    let size: CGSize

    @Environment(\.mossTheme) private var theme

    var body: some View {
        Canvas { context, canvasSize in
            let logicalMinX = viewport.offset.x - canvasSize.width / (2 * max(viewport.scale, 0.1))
            let logicalMaxX = viewport.offset.x + canvasSize.width / (2 * max(viewport.scale, 0.1))
            let logicalMinY = viewport.offset.y - canvasSize.height / (2 * max(viewport.scale, 0.1))
            let logicalMaxY = viewport.offset.y + canvasSize.height / (2 * max(viewport.scale, 0.1))

            let minorStep = TerminalCanvasMetrics.gridStep
            let majorStep = minorStep * 4

            var minorPath = Path()
            var majorPath = Path()

            var x = floor(logicalMinX / minorStep) * minorStep
            while x <= logicalMaxX {
                let screenX = (x - viewport.offset.x) * viewport.scale + canvasSize.width / 2
                if isMajorLine(x, majorStep: majorStep) {
                    majorPath.move(to: CGPoint(x: screenX, y: 0))
                    majorPath.addLine(to: CGPoint(x: screenX, y: canvasSize.height))
                } else {
                    minorPath.move(to: CGPoint(x: screenX, y: 0))
                    minorPath.addLine(to: CGPoint(x: screenX, y: canvasSize.height))
                }
                x += minorStep
            }

            var y = floor(logicalMinY / minorStep) * minorStep
            while y <= logicalMaxY {
                let screenY = (y - viewport.offset.y) * viewport.scale + canvasSize.height / 2
                if isMajorLine(y, majorStep: majorStep) {
                    majorPath.move(to: CGPoint(x: 0, y: screenY))
                    majorPath.addLine(to: CGPoint(x: canvasSize.width, y: screenY))
                } else {
                    minorPath.move(to: CGPoint(x: 0, y: screenY))
                    minorPath.addLine(to: CGPoint(x: canvasSize.width, y: screenY))
                }
                y += minorStep
            }

            context.fill(
                Path(CGRect(origin: .zero, size: canvasSize)),
                with: .color(theme?.background ?? Color.black)
            )
            context.stroke(
                minorPath,
                with: .color((theme?.border ?? .white).opacity(0.08)),
                lineWidth: 1
            )
            context.stroke(
                majorPath,
                with: .color((theme?.border ?? .white).opacity(0.22)),
                lineWidth: 1
            )
        }
        .frame(width: size.width, height: size.height)
    }

    private func isMajorLine(_ value: CGFloat, majorStep: CGFloat) -> Bool {
        let remainder = abs(value.truncatingRemainder(dividingBy: majorStep))
        return remainder < 0.5 || abs(remainder - majorStep) < 0.5
    }
}

private enum SurfaceFocusCoordinator {
    static func focus(_ session: TerminalSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard let window = NSApplication.shared.mainWindow
                ?? NSApplication.shared.keyWindow
            else { return }

            var surfaceViews: [MossSurfaceView] = []
            collectSurfaceViews(in: window.contentView, into: &surfaceViews)
            for view in surfaceViews where view.sessionId == session.id {
                window.makeFirstResponder(view)
                return
            }
        }
    }

    private static func collectSurfaceViews(
        in view: NSView?,
        into result: inout [MossSurfaceView]
    ) {
        guard let view else { return }
        if let surfaceView = view as? MossSurfaceView {
            result.append(surfaceView)
            return
        }
        for subview in view.subviews {
            collectSurfaceViews(in: subview, into: &result)
        }
    }
}

private struct CardHeaderButton: View {
    let systemImage: String
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption)
                .scaleEffect(isHovered ? 1.5 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                isHovered = true
                NSCursor.pointingHand.push()
            case .ended:
                isHovered = false
                NSCursor.pop()
            }
        }
    }
}
