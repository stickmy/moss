import AppKit
import SwiftUI

struct TerminalCanvasCardActions {
    let onFocus: () -> Void
    let onFit: () -> Void
    let onClose: () -> Void
    let onInteractionChanged: (Bool) -> Void
    let resolveMove: (_ originalRect: CGRect, _ translation: CGSize) -> CGRect
    let commitMove: (_ rect: CGRect) -> Void
    let onResize: (_ handle: TerminalCanvasResizeHandle, _ originalRect: CGRect, _ translation: CGSize) -> Void
}

struct TerminalCanvasCard: View {
    private let showLayoutDebug = false
    private let cardCornerRadius: CGFloat = 2

    @Bindable var session: TerminalSession
    let logicalRect: CGRect
    let screenRect: CGRect
    let scale: CGFloat
    let isAppearanceFocused: Bool
    let isInteracting: Bool
    let actions: TerminalCanvasCardActions

    @Environment(\.mossTheme) private var theme

    private var headerHeight: CGFloat {
        max(44, 48 * scale)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        cardSurface(showFitButton: true) {
            TerminalSplitContentView(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if let searchState = session.searchState {
                        TerminalSearchOverlay(
                            searchState: searchState,
                            onNavigate: { session.navigateSearch($0) },
                            onClose: { session.endSearch() }
                        )
                    }
                }
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
            return theme.borderSubtle
        }
        return theme.border.opacity(0.75)
    }

    private var accentColor: Color {
        theme.foreground.opacity(0.6)
    }

    private var statusBarColor: Color {
        if session.status != .none {
            return theme.color(for: session.status)
        }
        if isAppearanceFocused {
            return accentColor
        }
        return .clear
    }

    @ViewBuilder
    private func cardSurface<Content: View>(
        showFitButton: Bool,
        @ViewBuilder terminalContent: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            header(showFitButton: showFitButton)
                .frame(height: headerHeight)
                .zIndex(1)

            terminalContent()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(width: screenRect.width, height: screenRect.height)
        .background(theme.surfaceBackground.opacity(0.96))
        .clipShape(cardShape)
        .overlay {
            cardShape
                .strokeBorder(borderColor, lineWidth: 1)
        }
        .overlay(alignment: .top) {
            statusBarColor
                .frame(height: 3)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: cardCornerRadius,
                    topTrailingRadius: cardCornerRadius
                ))
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
                        .fill(session.status == .none
                            ? theme.secondaryForeground.opacity(0.7)
                            : theme.color(for: session.status))
                        .frame(width: 8, height: 8)

                    if !session.trackedTasks.isEmpty {
                        TaskProgressIndicator(tasks: session.trackedTasks)
                    } else if let activity = session.activitySummary {
                        Text(activity)
                            .font(.caption2)
                            .foregroundStyle(theme.secondaryForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(activity)
                    }

                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showFitButton {
                CardHeaderButton(systemImage: "viewfinder", color: theme.secondaryForeground, action: actions.onFit)
                CardHeaderButton(systemImage: "xmark", color: theme.secondaryForeground, action: actions.onClose)
            } else {
                Image(systemName: "viewfinder")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForeground.opacity(0.55))

                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryForeground.opacity(0.55))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Rectangle()
                .fill(theme.raisedBackground)
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
            actions: actions
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
                    actions: actions
                )
            }
        }
    }

    private var interactiveResizeHandles: [TerminalCanvasResizeHandle] {
        TerminalCanvasResizeHandle.allCases
    }
}

// MARK: - Resize Handles

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
    let actions: TerminalCanvasCardActions

    @State private var resizeStartRect: CGRect?
    @State private var isHovered = false

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
                    if !isHovered {
                        handleCursor.push()
                        isHovered = true
                    }
                } else {
                    if isHovered && resizeStartRect == nil {
                        NSCursor.pop()
                        isHovered = false
                    }
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
                    actions.onInteractionChanged(true)
                    actions.onFocus()
                }
                guard let resizeStartRect else { return }
                let translation = CGSize(
                    width: value.translation.width / max(scale, 0.1),
                    height: value.translation.height / max(scale, 0.1)
                )
                actions.onResize(handle, resizeStartRect, translation)
            }
            .onEnded { _ in
                resizeStartRect = nil
                actions.onInteractionChanged(false)
                if isHovered {
                    // Still hovering — keep the resize cursor visible
                } else {
                    // Mouse left during drag — pop the cursor now
                    NSCursor.pop()
                    isHovered = false
                }
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

// MARK: - Native Drag Handle

private struct TerminalCanvasNativeHeaderDragHandle: NSViewRepresentable {
    let logicalRect: CGRect
    let screenRect: CGRect
    let scale: CGFloat
    let headerHeight: CGFloat
    let actions: TerminalCanvasCardActions

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
        view.onFocus = actions.onFocus
        view.onInteractionChanged = actions.onInteractionChanged
        view.resolveMove = actions.resolveMove
        view.commitMove = actions.commitMove
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

// MARK: - Card Header Button

struct CardHeaderButton: View {
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
        .pointerCursor()
        .onHover { isHovered = $0 }
    }
}
