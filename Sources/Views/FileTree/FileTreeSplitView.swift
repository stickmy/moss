import AppKit
import SwiftUI

// MARK: - NSView Container

/// An NSView that manages a file-tree / canvas split layout with a draggable divider.
/// During drag, only NSView frames change — no SwiftUI state is touched — so the terminal
/// canvas resizes without the flicker caused by SwiftUI's re-evaluation pipeline.
final class FileTreeSplitNSView: NSView {
    private let leftContainer = NSView()
    private let dividerLine = NSView()
    private let handleView = SplitDividerHandleView()
    private(set) var leftHostingView: NSView?
    private(set) var rightHostingView: NSView?

    private var dividerPosition: CGFloat
    private let minPosition: CGFloat
    private let maxPosition: CGFloat
    private let dividerVisualWidth: CGFloat = 1
    private let handleHitWidth: CGFloat = 11

    private(set) var isDragging = false
    private var dragStartX: CGFloat = 0
    private var dragStartPosition: CGFloat = 0
    private var showLeft = true

    var onPositionChange: ((CGFloat) -> Void)?

    init(dividerPosition: CGFloat, minPosition: CGFloat, maxPosition: CGFloat) {
        self.dividerPosition = dividerPosition
        self.minPosition = minPosition
        self.maxPosition = maxPosition
        super.init(frame: .zero)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true

        leftContainer.wantsLayer = true
        leftContainer.layer?.masksToBounds = true
        addSubview(leftContainer)

        dividerLine.wantsLayer = true
        addSubview(dividerLine)

        handleView.owner = self
        addSubview(handleView)
    }

    func setLeftHostingView(_ view: NSView) {
        leftHostingView?.removeFromSuperview()
        leftHostingView = view
        leftContainer.addSubview(view)
        needsLayout = true
    }

    func setRightHostingView(_ view: NSView) {
        rightHostingView?.removeFromSuperview()
        rightHostingView = view
        // Insert below divider/handle so they stay on top
        addSubview(view, positioned: .below, relativeTo: dividerLine)
        needsLayout = true
    }

    func updateShowLeft(_ show: Bool) {
        guard showLeft != show else { return }
        showLeft = show
        needsLayout = true
    }

    func updateDividerPosition(_ pos: CGFloat) {
        guard !isDragging else { return }
        dividerPosition = pos
        needsLayout = true
    }

    func updateDividerColor(_ color: NSColor) {
        dividerLine.layer?.backgroundColor = color.cgColor
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if showLeft {
            let leftWidth = dividerPosition

            leftContainer.frame = CGRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
            leftHostingView?.frame = leftContainer.bounds
            leftContainer.isHidden = false

            dividerLine.frame = CGRect(x: leftWidth, y: 0, width: dividerVisualWidth, height: bounds.height)
            dividerLine.isHidden = false

            handleView.frame = CGRect(
                x: leftWidth + dividerVisualWidth / 2 - handleHitWidth / 2,
                y: 0,
                width: handleHitWidth,
                height: bounds.height
            )
            handleView.isHidden = false

            let rightX = leftWidth + dividerVisualWidth
            let rightWidth = bounds.width - rightX
            rightHostingView?.frame = CGRect(x: rightX, y: 0, width: max(0, rightWidth), height: bounds.height)
        } else {
            leftContainer.isHidden = true
            dividerLine.isHidden = true
            handleView.isHidden = true
            rightHostingView?.frame = bounds
        }

        CATransaction.commit()
    }

    // MARK: - Mouse Events (forwarded from handleView)

    func handleMouseDown(with event: NSEvent) {
        isDragging = true
        dragStartX = event.locationInWindow.x
        dragStartPosition = dividerPosition
        NSCursor.resizeLeftRight.push()
    }

    func handleMouseDragged(with event: NSEvent) {
        let delta = event.locationInWindow.x - dragStartX
        dividerPosition = max(minPosition, min(maxPosition, dragStartPosition + delta))
        needsLayout = true
        onPositionChange?(dividerPosition)
    }

    func handleMouseUp(with _: NSEvent) {
        isDragging = false
        NSCursor.pop()
        onPositionChange?(dividerPosition)
    }
}

// MARK: - Divider Handle View

private final class SplitDividerHandleView: NSView {
    weak var owner: FileTreeSplitNSView?
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

    override func cursorUpdate(with _: NSEvent) {
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

struct FileTreeSplitContainer: NSViewRepresentable {
    let leftContent: AnyView?
    let rightContent: AnyView
    @Binding var dividerPosition: CGFloat
    let minPosition: CGFloat
    let maxPosition: CGFloat
    let dividerColor: NSColor

    func makeCoordinator() -> Coordinator {
        Coordinator(dividerPosition: $dividerPosition)
    }

    func makeNSView(context: Context) -> FileTreeSplitNSView {
        let split = FileTreeSplitNSView(
            dividerPosition: dividerPosition,
            minPosition: minPosition,
            maxPosition: maxPosition
        )

        if let leftContent {
            split.setLeftHostingView(NSHostingView(rootView: leftContent))
        }
        split.setRightHostingView(NSHostingView(rootView: rightContent))
        split.updateShowLeft(leftContent != nil)
        split.updateDividerColor(dividerColor)
        split.onPositionChange = { newPos in
            context.coordinator.dividerPosition.wrappedValue = newPos
        }
        return split
    }

    func updateNSView(_ split: FileTreeSplitNSView, context: Context) {
        let showLeft = leftContent != nil

        if showLeft {
            if let leftHosting = split.leftHostingView as? NSHostingView<AnyView>,
               let leftContent
            {
                leftHosting.rootView = leftContent
            } else if let leftContent {
                split.setLeftHostingView(NSHostingView(rootView: leftContent))
            }
        }

        if let rightHosting = split.rightHostingView as? NSHostingView<AnyView> {
            rightHosting.rootView = rightContent
        }

        split.updateShowLeft(showLeft)
        split.updateDividerColor(dividerColor)
        split.updateDividerPosition(dividerPosition)
    }

    class Coordinator {
        let dividerPosition: Binding<CGFloat>
        init(dividerPosition: Binding<CGFloat>) {
            self.dividerPosition = dividerPosition
        }
    }
}
