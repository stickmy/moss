import AppKit
import SwiftUI

// MARK: - SwiftUI Bridge

struct TerminalSplitContentView: NSViewRepresentable {
    @Bindable var session: TerminalSession
    @Environment(\.mossTheme) private var theme

    func makeNSView(context: Context) -> TerminalSplitNSView {
        let view = TerminalSplitNSView()
        view.session = session
        view.theme = theme
        view.rebuild()
        return view
    }

    func updateNSView(_ nsView: TerminalSplitNSView, context: Context) {
        nsView.session = session
        nsView.theme = theme
        nsView.rebuildIfStructureChanged()
    }
}

// MARK: - Native Split Container

@MainActor
final class TerminalSplitNSView: NSView {
    var session: TerminalSession?
    var theme: MossTheme = .fallback

    /// Leaf IDs from the last rebuild — detect structural changes.
    private var lastLeafIds: [UUID] = []
    private var lastActiveSurfaceId: UUID?

    /// Overlay views for unfocused panes.
    private var unfocusedOverlays: [UUID: NSView] = [:]

    /// Divider hit-test info computed during layout.
    private var dividerInfos: [DividerInfo] = []

    /// Active drag state (nil when not dragging).
    private var activeDrag: DragState?

    override var isFlipped: Bool { true }

    struct DividerInfo {
        let firstChildLeafId: UUID
        let direction: SplitDirection
        let visualRect: CGRect
        let hitRect: CGRect
        let totalSpace: CGFloat
        let currentRatio: CGFloat
    }

    struct DragState {
        let firstChildLeafId: UUID
        let direction: SplitDirection
        let totalSpace: CGFloat
        let startRatio: CGFloat
        let startMousePos: CGFloat // x or y depending on direction
        var currentRatio: CGFloat
    }

    // MARK: - Rebuild

    func rebuild() {
        guard let session else { return }
        let leafIds = session.splitRoot.allLeafIds()
        lastLeafIds = leafIds
        lastActiveSurfaceId = session.activeSurfaceId

        // Remove stale subviews
        let leafIdSet = Set(leafIds)
        for subview in subviews {
            if let hostView = subview as? MossSurfaceHostView {
                let leafId = leafIds.first { session.surfaceHostView(for: $0) === hostView }
                if leafId == nil || !leafIdSet.contains(leafId!) {
                    hostView.removeFromSuperview()
                }
            }
        }

        // Ensure all leaf host views are added
        for leafId in leafIds {
            let hostView = session.surfaceHostView(for: leafId)
            let surfaceView = session.surfaceView(for: leafId)
            hostView.setSurfaceView(surfaceView)
            surfaceView.leafId = leafId
            surfaceView.isActive = true
            surfaceView.isHidden = false
            if hostView.superview !== self {
                hostView.removeFromSuperview()
                addSubview(hostView)
            }
        }

        // Clean up old overlays
        for (id, overlay) in unfocusedOverlays where !leafIdSet.contains(id) {
            overlay.removeFromSuperview()
            unfocusedOverlays.removeValue(forKey: id)
        }

        needsLayout = true
    }

    func rebuildIfStructureChanged() {
        guard let session else { return }
        let leafIds = session.splitRoot.allLeafIds()
        if leafIds != lastLeafIds {
            rebuild()
        } else if session.activeSurfaceId != lastActiveSurfaceId {
            lastActiveSurfaceId = session.activeSurfaceId
            updateUnfocusedOverlays()
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let session else { return }

        let effectiveRoot: TerminalSplitNode
        if let drag = activeDrag {
            effectiveRoot = session.splitRoot.updatingRatioForSplit(
                firstChildLeafId: drag.firstChildLeafId,
                newRatio: drag.currentRatio
            )
        } else {
            effectiveRoot = session.splitRoot
        }

        let layoutResult = TerminalSplitLayoutCalc.build(
            node: effectiveRoot,
            in: CGRect(origin: .zero, size: bounds.size),
            dividerThickness: 1
        )

        // Apply leaf frames
        for leaf in layoutResult.leaves {
            let hostView = session.surfaceHostView(for: leaf.id)
            if hostView.frame != leaf.frame {
                hostView.frame = leaf.frame
            }
        }

        // Store divider info for hit-testing and drawing
        dividerInfos = layoutResult.dividers.map { d in
            let hitInset: CGFloat = -5 // expand 5px each side → 11px hit area
            return DividerInfo(
                firstChildLeafId: d.firstChildLeafId,
                direction: d.direction,
                visualRect: d.frame,
                hitRect: d.direction == .horizontal
                    ? d.frame.insetBy(dx: hitInset, dy: 0)
                    : d.frame.insetBy(dx: 0, dy: hitInset),
                totalSpace: d.totalSpace,
                currentRatio: d.ratio
            )
        }

        updateUnfocusedOverlays()
        setNeedsDisplay(bounds)
    }

    // MARK: - Unfocused Overlay

    private func updateUnfocusedOverlays() {
        guard let session else { return }
        let isSplit: Bool
        if case .split = session.splitRoot { isSplit = true } else { isSplit = false }
        guard isSplit, theme.unfocusedSplitOpacity > 0 else {
            for (_, overlay) in unfocusedOverlays {
                overlay.removeFromSuperview()
            }
            unfocusedOverlays.removeAll()
            return
        }

        for leafId in lastLeafIds {
            let isActive = session.activeSurfaceId == leafId
            let hostView = session.surfaceHostView(for: leafId)

            if !isActive {
                let overlay: NSView
                if let existing = unfocusedOverlays[leafId] {
                    overlay = existing
                } else {
                    overlay = NSView()
                    overlay.wantsLayer = true
                    unfocusedOverlays[leafId] = overlay
                }
                overlay.layer?.backgroundColor = NSColor(theme.unfocusedSplitFill)
                    .withAlphaComponent(theme.unfocusedSplitOpacity).cgColor
                overlay.frame = hostView.frame
                if overlay.superview !== self {
                    addSubview(overlay, positioned: .above, relativeTo: hostView)
                }
                overlay.alphaValue = 1
            } else {
                if let overlay = unfocusedOverlays[leafId] {
                    overlay.removeFromSuperview()
                    unfocusedOverlays.removeValue(forKey: leafId)
                }
            }
        }
    }

    // MARK: - Drawing (dividers)

    override func draw(_ dirtyRect: NSRect) {
        guard !dividerInfos.isEmpty else { return }
        NSColor.separatorColor.setFill()
        for info in dividerInfos {
            NSBezierPath.fill(info.visualRect)
        }
    }

    // MARK: - Hit Testing

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if dividerAtPoint(local) != nil {
            return self
        }
        return super.hitTest(point)
    }

    // MARK: - Mouse Handling (divider drag)

    private func dividerAtPoint(_ point: CGPoint) -> DividerInfo? {
        dividerInfos.first { $0.hitRect.contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = dividerAtPoint(point) else {
            super.mouseDown(with: event)
            return
        }

        let mousePos = divider.direction == .horizontal ? point.x : point.y
        activeDrag = DragState(
            firstChildLeafId: divider.firstChildLeafId,
            direction: divider.direction,
            totalSpace: divider.totalSpace,
            startRatio: divider.currentRatio,
            startMousePos: mousePos,
            currentRatio: divider.currentRatio
        )

        let cursor: NSCursor = divider.direction == .horizontal ? .resizeLeftRight : .resizeUpDown
        cursor.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag = activeDrag else {
            super.mouseDragged(with: event)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        let mousePos = drag.direction == .horizontal ? point.x : point.y
        let delta = mousePos - drag.startMousePos
        let ratioDelta = delta / drag.totalSpace
        drag.currentRatio = min(0.9, max(0.1, drag.startRatio + ratioDelta))
        activeDrag = drag

        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = activeDrag else {
            super.mouseUp(with: event)
            return
        }

        session?.updateSplitRatio(
            firstChildLeafId: drag.firstChildLeafId,
            ratio: drag.currentRatio
        )
        activeDrag = nil
        NSCursor.pop()
    }

    // MARK: - Cursor Tracking

    private var isCursorOverDivider = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let divider = dividerAtPoint(point) {
            if !isCursorOverDivider {
                let cursor: NSCursor = divider.direction == .horizontal ? .resizeLeftRight : .resizeUpDown
                cursor.push()
                isCursorOverDivider = true
            }
        } else {
            if isCursorOverDivider {
                NSCursor.pop()
                isCursorOverDivider = false
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if isCursorOverDivider {
            NSCursor.pop()
            isCursorOverDivider = false
        }
    }
}

// MARK: - Layout Calculator (pure value types, no views)

private struct TerminalSplitLayoutCalc {
    struct Leaf: Identifiable {
        let id: UUID
        let frame: CGRect
    }

    struct Divider: Identifiable {
        let id: UUID
        let firstChildLeafId: UUID
        let direction: SplitDirection
        let totalSpace: CGFloat
        let frame: CGRect
        let ratio: CGFloat
    }

    let leaves: [Leaf]
    let dividers: [Divider]

    static func build(
        node: TerminalSplitNode,
        in rect: CGRect,
        dividerThickness: CGFloat
    ) -> TerminalSplitLayoutCalc {
        var leaves: [Leaf] = []
        var dividers: [Divider] = []
        append(
            node: node,
            rect: rect,
            dividerThickness: dividerThickness,
            leaves: &leaves,
            dividers: &dividers
        )
        return TerminalSplitLayoutCalc(leaves: leaves, dividers: dividers)
    }

    private static func append(
        node: TerminalSplitNode,
        rect: CGRect,
        dividerThickness: CGFloat,
        leaves: inout [Leaf],
        dividers: inout [Divider]
    ) {
        switch node {
        case .leaf(let id):
            leaves.append(Leaf(id: id, frame: rect))

        case .split(let direction, let ratio, let first, let second):
            let clampedRatio = min(0.9, max(0.1, ratio))

            if direction == .horizontal {
                let totalWidth = rect.width
                let firstWidth = max(0, totalWidth * clampedRatio - dividerThickness / 2)
                let dividerX = rect.minX + firstWidth
                let secondX = dividerX + dividerThickness
                let secondWidth = max(0, rect.maxX - secondX)

                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
                let dividerRect = CGRect(x: dividerX, y: rect.minY, width: dividerThickness, height: rect.height)
                let secondRect = CGRect(x: secondX, y: rect.minY, width: secondWidth, height: rect.height)

                if let firstChildLeafId = first.allLeafIds().first {
                    dividers.append(Divider(
                        id: firstChildLeafId,
                        firstChildLeafId: firstChildLeafId,
                        direction: direction,
                        totalSpace: totalWidth,
                        frame: dividerRect,
                        ratio: clampedRatio
                    ))
                }

                append(node: first, rect: firstRect, dividerThickness: dividerThickness, leaves: &leaves, dividers: &dividers)
                append(node: second, rect: secondRect, dividerThickness: dividerThickness, leaves: &leaves, dividers: &dividers)
            } else {
                let totalHeight = rect.height
                let firstHeight = max(0, totalHeight * clampedRatio - dividerThickness / 2)
                let dividerY = rect.minY + firstHeight
                let secondY = dividerY + dividerThickness
                let secondHeight = max(0, rect.maxY - secondY)

                let firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
                let dividerRect = CGRect(x: rect.minX, y: dividerY, width: rect.width, height: dividerThickness)
                let secondRect = CGRect(x: rect.minX, y: secondY, width: rect.width, height: secondHeight)

                if let firstChildLeafId = first.allLeafIds().first {
                    dividers.append(Divider(
                        id: firstChildLeafId,
                        firstChildLeafId: firstChildLeafId,
                        direction: direction,
                        totalSpace: totalHeight,
                        frame: dividerRect,
                        ratio: clampedRatio
                    ))
                }

                append(node: first, rect: firstRect, dividerThickness: dividerThickness, leaves: &leaves, dividers: &dividers)
                append(node: second, rect: secondRect, dividerThickness: dividerThickness, leaves: &leaves, dividers: &dividers)
            }
        }
    }
}
