import AppKit
import SwiftUI

// MARK: - NSView Container

/// An NSView that hosts SwiftUI content and handles resize via direct frame manipulation,
/// bypassing SwiftUI's state-driven layout (same pattern as terminal split dividers).
final class ResizablePanelNSView: NSView {
    private(set) var contentHostingView: NSView?
    private let clipContainer = NSView()
    private let handleView = ResizeHandleView()

    private var panelWidth: CGFloat
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let cornerRadius: CGFloat = 10

    // Drag state (local, not SwiftUI)
    private(set) var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    // Resize handle
    private let handleHitWidth: CGFloat = 11

    // Callback on drag end
    var onWidthCommit: ((CGFloat) -> Void)?

    init(panelWidth: CGFloat, minWidth: CGFloat, maxWidth: CGFloat) {
        self.panelWidth = panelWidth
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setupViews() {
        wantsLayer = true
        layer?.masksToBounds = false

        clipContainer.wantsLayer = true
        clipContainer.layer?.cornerRadius = cornerRadius
        clipContainer.layer?.masksToBounds = true
        addSubview(clipContainer)

        // Handle view sits ABOVE clipContainer to always receive cursor events
        handleView.owner = self
        addSubview(handleView)
    }

    func setHostingView(_ view: NSView) {
        contentHostingView?.removeFromSuperview()
        contentHostingView = view
        clipContainer.addSubview(view)
        needsLayout = true
    }

    func updatePanelWidth(_ w: CGFloat) {
        guard !isDragging else { return }
        panelWidth = w
        needsLayout = true
    }

    func updateBorderColor(_ color: NSColor) {
        clipContainer.layer?.borderColor = color.withAlphaComponent(0.5).cgColor
        clipContainer.layer?.borderWidth = 1
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let panelFrame = CGRect(x: 0, y: 0, width: panelWidth, height: bounds.height)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipContainer.frame = panelFrame
        contentHostingView?.frame = clipContainer.bounds
        handleView.frame = CGRect(
            x: panelWidth - handleHitWidth / 2,
            y: 0,
            width: handleHitWidth,
            height: bounds.height
        )
        CATransaction.commit()
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let hitArea = CGRect(
            x: 0, y: 0,
            width: panelWidth + handleHitWidth / 2,
            height: bounds.height
        )
        guard hitArea.contains(local) else { return nil }
        // Let the handle view get priority
        let handleHit = handleView.hitTest(convert(local, to: handleView))
        if handleHit != nil { return handleHit }
        return super.hitTest(point)
    }

    // MARK: - Mouse Events (forwarded from handleView)

    func handleMouseDown(with event: NSEvent) {
        isDragging = true
        dragStartX = event.locationInWindow.x
        dragStartWidth = panelWidth
        NSCursor.resizeLeftRight.push()
    }

    func handleMouseDragged(with event: NSEvent) {
        let delta = event.locationInWindow.x - dragStartX
        panelWidth = max(minWidth, min(maxWidth, dragStartWidth + delta))
        needsLayout = true
    }

    func handleMouseUp(with event: NSEvent) {
        isDragging = false
        NSCursor.pop()
        onWidthCommit?(panelWidth)
    }
}

// MARK: - Resize Handle View

/// Transparent NSView that sits above content to reliably capture cursor and mouse events.
private final class ResizeHandleView: NSView {
    weak var owner: ResizablePanelNSView?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .cursorUpdate],
            owner: self
        )
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        owner?.handleMouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.handleMouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.handleMouseUp(with: event)
    }
}

// MARK: - NSViewRepresentable

struct ResizablePanelContainer: NSViewRepresentable {
    let content: AnyView
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let borderColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(width: $width)
    }

    func makeNSView(context: Context) -> ResizablePanelNSView {
        let panel = ResizablePanelNSView(
            panelWidth: width,
            minWidth: minWidth,
            maxWidth: maxWidth
        )
        let hosting = NSHostingView(rootView: content)
        panel.setHostingView(hosting)
        panel.updateBorderColor(borderColor)
        panel.onWidthCommit = { newWidth in
            context.coordinator.width.wrappedValue = newWidth
        }
        return panel
    }

    func updateNSView(_ panel: ResizablePanelNSView, context: Context) {
        if let hosting = panel.contentHostingView as? NSHostingView<AnyView> {
            hosting.rootView = content
        }
        panel.updateBorderColor(borderColor)
        panel.updatePanelWidth(width)
    }

    class Coordinator {
        let width: Binding<CGFloat>
        init(width: Binding<CGFloat>) {
            self.width = width
        }
    }
}
