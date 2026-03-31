import AppKit
import SwiftUI

struct TerminalSplitContentView: View {
    @Bindable var session: TerminalSession

    private let dividerThickness: CGFloat = 1

    private var isSplit: Bool {
        if case .split = session.splitRoot { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            let layout = TerminalSplitLayout.build(
                node: session.splitRoot,
                in: CGRect(origin: .zero, size: geo.size),
                dividerThickness: dividerThickness
            )

            ZStack(alignment: .topLeading) {
                ForEach(layout.leaves) { leaf in
                    TerminalSplitLeafView(
                        session: session,
                        leafId: leaf.id,
                        isSplit: isSplit
                    )
                    .frame(width: max(0, leaf.frame.width), height: max(0, leaf.frame.height))
                    .offset(x: leaf.frame.minX, y: leaf.frame.minY)
                }

                ForEach(layout.dividers) { divider in
                    SplitDivider(
                        direction: divider.direction,
                        totalSpace: divider.totalSpace,
                        onRatioChanged: { newRatio in
                            session.updateSplitRatio(
                                firstChildLeafId: divider.firstChildLeafId,
                                ratio: newRatio
                            )
                        }
                    )
                    .frame(
                        width: divider.direction == .horizontal ? 7 : divider.frame.width,
                        height: divider.direction == .horizontal ? divider.frame.height : 7
                    )
                    .position(x: divider.frame.midX, y: divider.frame.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Leaf View (terminal + unfocused overlay)

private struct TerminalSplitLeafView: View {
    @Bindable var session: TerminalSession
    let leafId: UUID
    let isSplit: Bool

    @Environment(\.mossTheme) private var theme

    var body: some View {
        let isActive = session.activeSurfaceId == leafId
        StableTerminalWrapper(session: session, leafId: leafId, isActive: true)
            .overlay {
                if isSplit && !isActive && theme.unfocusedSplitOpacity > 0 {
                    Rectangle()
                        .fill(theme.unfocusedSplitFill)
                        .opacity(theme.unfocusedSplitOpacity)
                        .allowsHitTesting(false)
                }
            }
    }
}

// MARK: - Layout

private struct TerminalSplitLayout {
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
    }

    let leaves: [Leaf]
    let dividers: [Divider]

    static func build(
        node: TerminalSplitNode,
        in rect: CGRect,
        dividerThickness: CGFloat
    ) -> TerminalSplitLayout {
        var leaves: [Leaf] = []
        var dividers: [Divider] = []
        append(
            node: node,
            rect: rect,
            dividerThickness: dividerThickness,
            leaves: &leaves,
            dividers: &dividers
        )
        return TerminalSplitLayout(leaves: leaves, dividers: dividers)
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

                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: firstWidth,
                    height: rect.height
                )
                let dividerRect = CGRect(
                    x: dividerX,
                    y: rect.minY,
                    width: dividerThickness,
                    height: rect.height
                )
                let secondRect = CGRect(
                    x: secondX,
                    y: rect.minY,
                    width: secondWidth,
                    height: rect.height
                )

                if let firstChildLeafId = first.allLeafIds().first {
                    dividers.append(
                        Divider(
                            id: firstChildLeafId,
                            firstChildLeafId: firstChildLeafId,
                            direction: direction,
                            totalSpace: totalWidth,
                            frame: dividerRect
                        )
                    )
                }

                append(
                    node: first,
                    rect: firstRect,
                    dividerThickness: dividerThickness,
                    leaves: &leaves,
                    dividers: &dividers
                )
                append(
                    node: second,
                    rect: secondRect,
                    dividerThickness: dividerThickness,
                    leaves: &leaves,
                    dividers: &dividers
                )
            } else {
                let totalHeight = rect.height
                let firstHeight = max(0, totalHeight * clampedRatio - dividerThickness / 2)
                let dividerY = rect.minY + firstHeight
                let secondY = dividerY + dividerThickness
                let secondHeight = max(0, rect.maxY - secondY)

                let firstRect = CGRect(
                    x: rect.minX,
                    y: rect.minY,
                    width: rect.width,
                    height: firstHeight
                )
                let dividerRect = CGRect(
                    x: rect.minX,
                    y: dividerY,
                    width: rect.width,
                    height: dividerThickness
                )
                let secondRect = CGRect(
                    x: rect.minX,
                    y: secondY,
                    width: rect.width,
                    height: secondHeight
                )

                if let firstChildLeafId = first.allLeafIds().first {
                    dividers.append(
                        Divider(
                            id: firstChildLeafId,
                            firstChildLeafId: firstChildLeafId,
                            direction: direction,
                            totalSpace: totalHeight,
                            frame: dividerRect
                        )
                    )
                }

                append(
                    node: first,
                    rect: firstRect,
                    dividerThickness: dividerThickness,
                    leaves: &leaves,
                    dividers: &dividers
                )
                append(
                    node: second,
                    rect: secondRect,
                    dividerThickness: dividerThickness,
                    leaves: &leaves,
                    dividers: &dividers
                )
            }
        }
    }
}

// MARK: - Split Divider

private struct SplitDivider: View {
    let direction: SplitDirection
    let totalSpace: CGFloat
    let onRatioChanged: (CGFloat) -> Void

    @State private var dragStartRatio: CGFloat?
    @State private var isShowingResizeCursor = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: direction == .horizontal ? 1 : nil,
                    height: direction == .vertical ? 1 : nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active:
                guard !isShowingResizeCursor else { return }
                let cursor: NSCursor = direction == .horizontal ? .resizeLeftRight : .resizeUpDown
                cursor.push()
                isShowingResizeCursor = true
            case .ended:
                releaseResizeCursor()
            }
        }
        .onDisappear {
            releaseResizeCursor()
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard totalSpace > 0 else { return }

                    if dragStartRatio == nil {
                        let startLocation = value.startLocation
                        if direction == .horizontal {
                            dragStartRatio = startLocation.x / totalSpace
                        } else {
                            dragStartRatio = startLocation.y / totalSpace
                        }
                    }

                    guard let dragStartRatio else { return }

                    let delta: CGFloat
                    if direction == .horizontal {
                        delta = value.translation.width
                    } else {
                        delta = value.translation.height
                    }

                    let ratioDelta = delta / totalSpace
                    let newRatio = min(0.9, max(0.1, dragStartRatio + ratioDelta))
                    onRatioChanged(newRatio)
                }
                .onEnded { _ in
                    dragStartRatio = nil
                }
        )
    }

    private func releaseResizeCursor() {
        guard isShowingResizeCursor else { return }
        NSCursor.pop()
        isShowingResizeCursor = false
    }
}
