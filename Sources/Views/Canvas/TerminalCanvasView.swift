import AppKit
import SwiftUI

private final class CanvasHoverRef {
    var isHovered = false
}

private final class CanvasSizeRef {
    var size: CGSize = .zero
    var overlayLeadingInset: CGFloat = 0
}

struct TerminalCanvasView: View {
    @Bindable var sessionManager: TerminalSessionManager
    let appearanceFocusedSessionId: UUID?
    var overlayLeadingInset: CGFloat = 0

    @State private var canvasSize: CGSize = .zero
    @State private var panStartOffset: CGPoint?
    @State private var zoomStartScale: CGFloat?
    @State private var interactingSessionId: UUID?
    @State private var hasRequestedInitialFocus = false
    @State private var scrollMonitor: EventMonitor?
    @State private var magnifyMonitor: EventMonitor?
    @State private var keyMonitor: EventMonitor?
    @State private var canvasHover = CanvasHoverRef()
    @State private var canvasSizeRef = CanvasSizeRef()
    @State private var zoomRestoreViewport: TerminalCanvasViewport?

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
                            actions: TerminalCanvasCardActions(
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
                                    canvasStore.updateRect(id: session.id, rect: rect)
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
            .overlay(alignment: .top) {
                canvasControls
                    .padding(.top, 6)
            }
            .onAppear {
                canvasSize = size
                canvasSizeRef.size = size
                canvasSizeRef.overlayLeadingInset = overlayLeadingInset
                requestInitialFocusIfNeeded()
                installScrollMonitor()
                installMagnifyMonitor()
                installKeyMonitor()
            }
            .onDisappear {
                scrollMonitor = nil
                magnifyMonitor = nil
                keyMonitor = nil
            }
            .onChange(of: size) { _, newValue in
                canvasSize = newValue
                canvasSizeRef.size = newValue
                requestInitialFocusIfNeeded()
                refitViewportIfNeeded(in: newValue)
            }
            .onChange(of: overlayLeadingInset) { _, newValue in
                canvasSizeRef.overlayLeadingInset = newValue
                refitFittedSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalNewRequested)) { _ in
                createNewSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalToggleZoom)) { _ in
                toggleZoomFocusedSession()
            }
            .onReceive(NotificationCenter.default.publisher(for: .terminalFocusRequested)) { notif in
                guard let sessionId = notif.userInfo?["sessionId"] as? UUID,
                      let session = sessionManager.sessions.first(where: { $0.id == sessionId })
                else { return }
                focusSession(session)
                fitViewport(to: session)
            }
        }
    }

    // MARK: - Gestures

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

    // MARK: - Controls

    private var canvasControls: some View {
        HStack(spacing: 4) {
            AgentStatusOverview(sessions: sessionManager.sessions)

            if sessionManager.sessions.contains(where: { $0.status != .none }) {
                Divider()
                    .frame(height: 12)
                    .opacity(0.5)
            }

            Text("\(Int(canvasStore.viewport.scale * 100))%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(sessionManager.theme.secondaryForeground)

            CanvasControlButton(systemImage: "minus", shortcutHint: "⌘−", action: { zoom(by: 0.9) })
            CanvasControlButton(systemImage: "plus", shortcutHint: "⌘+", action: { zoom(by: 1.1) })
            CanvasControlButton(label: "Reset", shortcutHint: "⌘0", action: {
                canvasStore.fitAllViewport(in: canvasSize, leadingInset: overlayLeadingInset)
            })
            CanvasControlButton(label: "Fit", shortcutHint: "⌘⇧↩", action: { fitFocusedSession() })
                .opacity(currentFocusTarget == nil ? 0.4 : 1)
                .disabled(currentFocusTarget == nil)
        }
        .font(.caption2)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
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

    // MARK: - Viewport

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

    private func toggleZoomFocusedSession() {
        guard let target = currentFocusTarget else { return }

        if let restore = zoomRestoreViewport {
            // Restore previous viewport
            zoomRestoreViewport = nil
            canvasStore.setViewport(restore)
        } else {
            // Save current viewport, then fit
            zoomRestoreViewport = canvasStore.viewport
            fitViewport(to: target)
        }
    }

    private func fitViewport(to session: TerminalSession) {
        canvasStore.fitViewport(to: session.id, in: canvasSize, leadingInset: overlayLeadingInset)
    }

    private func refitFittedSession() {
        guard let fittedId = canvasStore.viewport.fittedSessionId,
              let session = sessionManager.orderedSessions.first(where: { $0.id == fittedId })
        else { return }
        fitViewport(to: session)
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

        let minOffsetX = item.rect.maxX - halfW
        let maxOffsetX = item.rect.minX + halfW
        if minOffsetX > maxOffsetX {
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
        viewport.scale = TerminalCanvasMetrics.clampedScale(scale)
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

    // MARK: - Event Monitors

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        let store = canvasStore
        let hover = canvasHover
        scrollMonitor = EventMonitor(.scrollWheel) { event in
            guard hover.isHovered else { return event }
            guard let window = event.window else { return event }

            if event.modifierFlags.contains(.command) {
                let dy = event.scrollingDeltaY
                let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.03
                let factor = 1 + dy * sensitivity
                var viewport = store.viewport
                viewport.scale = TerminalCanvasMetrics.clampedScale(viewport.scale * factor)
                viewport.fittedSessionId = nil
                store.setViewport(viewport)
                return nil
            }

            if let focused = window.firstResponder as? MossSurfaceView {
                let point = focused.convert(event.locationInWindow, from: nil)
                if focused.bounds.contains(point) {
                    return event
                }
            }

            if let contentView = window.contentView {
                let windowPoint = contentView.convert(event.locationInWindow, from: nil)
                if let hitView = contentView.hitTest(windowPoint),
                   hitView.enclosingScrollView != nil
                {
                    return event
                }
            }

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

    private func installMagnifyMonitor() {
        guard magnifyMonitor == nil else { return }
        let store = canvasStore
        let hover = canvasHover
        magnifyMonitor = EventMonitor(.magnify) { event in
            guard hover.isHovered else { return event }

            var viewport = store.viewport
            let newScale = viewport.scale * (1 + event.magnification)
            viewport.scale = TerminalCanvasMetrics.clampedScale(newScale)
            viewport.fittedSessionId = nil
            store.setViewport(viewport)

            return nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let store = canvasStore
        let sizeRef = canvasSizeRef
        keyMonitor = EventMonitor(.keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            guard mods == .command else { return event }

            switch event.charactersIgnoringModifiers {
            case "=", "+":
                var viewport = store.viewport
                viewport.scale = TerminalCanvasMetrics.clampedScale(viewport.scale * 1.1)
                viewport.fittedSessionId = nil
                store.setViewport(viewport)
                return nil
            case "-":
                var viewport = store.viewport
                viewport.scale = TerminalCanvasMetrics.clampedScale(viewport.scale / 1.1)
                viewport.fittedSessionId = nil
                store.setViewport(viewport)
                return nil
            case "0":
                store.fitAllViewport(in: sizeRef.size, leadingInset: sizeRef.overlayLeadingInset)
                return nil
            default:
                return event
            }
        }
    }
}

// MARK: - Canvas Control Button

private struct CanvasControlButton: View {
    var systemImage: String?
    var label: String?
    var shortcutHint: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                } else if let label {
                    Text(label)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            if isHovered, let shortcutHint {
                Text(shortcutHint)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(.black.opacity(0.75))
                    )
                    .fixedSize()
                    .offset(y: 28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.1), value: isHovered)
            }
        }
    }
}
