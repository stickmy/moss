import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class TerminalCanvasStore {
    private(set) var viewport: TerminalCanvasViewport = .default
    private(set) var itemsById: [UUID: TerminalCanvasItemSnapshot] = [:]
    private(set) var didLoadPersistentSnapshot = false

    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?

    init() {
        loadSnapshot()
    }

    var items: [TerminalCanvasItemSnapshot] {
        itemsById.values.sorted { lhs, rhs in
            if lhs.createdOrder == rhs.createdOrder {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdOrder < rhs.createdOrder
        }
    }

    func item(for id: UUID) -> TerminalCanvasItemSnapshot? {
        itemsById[id]
    }

    func setViewport(_ viewport: TerminalCanvasViewport) {
        let nextViewport = TerminalCanvasViewport(
            offset: viewport.offset,
            scale: clampedScale(viewport.scale),
            fittedSessionId: viewport.fittedSessionId
        )
        guard self.viewport != nextViewport else { return }
        self.viewport = nextViewport
        scheduleSave()
    }

    func fitViewport(to sessionId: UUID, in canvasSize: CGSize) {
        guard let item = itemsById[sessionId],
              canvasSize.width > 0,
              canvasSize.height > 0
        else { return }

        let availableWidth = max(1, canvasSize.width - TerminalCanvasMetrics.fitPadding * 2)
        let availableHeight = max(1, canvasSize.height - TerminalCanvasMetrics.fitPadding * 2)
        let scale = min(
            availableWidth / max(1, item.rect.width),
            availableHeight / max(1, item.rect.height)
        )

        setViewport(
            TerminalCanvasViewport(
                offset: CGPoint(x: item.rect.midX, y: item.rect.midY),
                scale: clampedScale(scale),
                fittedSessionId: sessionId
            )
        )
    }

    func resetViewport() {
        setViewport(.default)
    }

    func nextRectForNewSession(
        focusedSessionId: UUID?,
        layoutHint: TerminalCanvasLayoutHint?
    ) -> CGRect {
        let desiredRect: CGRect
        if let focusedSessionId,
           let focusedItem = itemsById[focusedSessionId]
        {
            desiredRect = focusedItem.rect.offsetBy(
                dx: TerminalCanvasMetrics.spawnOffset.x,
                dy: TerminalCanvasMetrics.spawnOffset.y
            )
        } else if let preferredCenter = layoutHint?.preferredCenter {
            desiredRect = CGRect(
                x: preferredCenter.x - TerminalCanvasMetrics.defaultCardSize.width / 2,
                y: preferredCenter.y - TerminalCanvasMetrics.defaultCardSize.height / 2,
                width: TerminalCanvasMetrics.defaultCardSize.width,
                height: TerminalCanvasMetrics.defaultCardSize.height
            )
        } else {
            desiredRect = CGRect(
                x: viewport.offset.x - TerminalCanvasMetrics.defaultCardSize.width / 2,
                y: viewport.offset.y - TerminalCanvasMetrics.defaultCardSize.height / 2,
                width: TerminalCanvasMetrics.defaultCardSize.width,
                height: TerminalCanvasMetrics.defaultCardSize.height
            )
        }

        return firstAvailableRect(near: desiredRect, excluding: nil)
    }

    func registerSession(
        id: UUID,
        rect: CGRect,
        workingDirectory: String?
    ) {
        itemsById[id] = TerminalCanvasItemSnapshot(
            id: id,
            rect: sanitizedRect(rect),
            workingDirectory: workingDirectory,
            createdOrder: nextCreatedOrder()
        )
        scheduleSave()
    }

    func restoreSession(_ item: TerminalCanvasItemSnapshot) {
        itemsById[item.id] = TerminalCanvasItemSnapshot(
            id: item.id,
            rect: sanitizedRect(item.rect),
            workingDirectory: item.workingDirectory,
            createdOrder: item.createdOrder
        )
    }

    func updateRect(id: UUID, rect: CGRect) {
        guard var item = itemsById[id] else { return }
        let nextRect = sanitizedRect(rect)
        guard item.rect != nextRect else { return }
        item.rect = nextRect
        itemsById[id] = item
        scheduleSave()
    }

    func updateWorkingDirectory(id: UUID, workingDirectory: String) {
        guard var item = itemsById[id], item.workingDirectory != workingDirectory else { return }
        item.workingDirectory = workingDirectory
        itemsById[id] = item
        scheduleSave()
    }

    func removeItem(id: UUID) {
        guard itemsById.removeValue(forKey: id) != nil else { return }
        if viewport.fittedSessionId == id {
            viewport.fittedSessionId = nil
        }
        scheduleSave()
    }

    func resolvedMoveRect(
        for id: UUID,
        originalRect: CGRect,
        translation: CGSize
    ) -> CGRect {
        let others = items.filter { $0.id != id }
        var rect = originalRect.offsetBy(dx: translation.width, dy: translation.height)
        rect = snappedMoveRect(rect, others: others)
        return sanitizedRect(rect)
    }

    func resolvedResizeRect(
        for id: UUID,
        originalRect: CGRect,
        handle: TerminalCanvasResizeHandle,
        translation: CGSize
    ) -> CGRect {
        let others = items.filter { $0.id != id }
        var rect = originalRect

        if handle.movesMinX {
            rect.origin.x += translation.width
            rect.size.width -= translation.width
        }
        if handle.movesMaxX {
            rect.size.width += translation.width
        }
        if handle.movesMinY {
            rect.origin.y += translation.height
            rect.size.height -= translation.height
        }
        if handle.movesMaxY {
            rect.size.height += translation.height
        }

        rect = rectWithMinimumSize(rect, anchoredBy: handle)
        rect = snappedResizeRect(rect, handle: handle, others: others)
        rect = clampedResizeRect(rect, originalRect: originalRect, handle: handle, others: others)
        rect = rectWithMinimumSize(rect, anchoredBy: handle)

        return sanitizedRect(rect)
    }

    func forceSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        saveSnapshot()
    }

    private func nextCreatedOrder() -> Int {
        (itemsById.values.map(\.createdOrder).max() ?? -1) + 1
    }

    private func loadSnapshot() {
        let url = snapshotURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(TerminalCanvasSnapshot.self, from: data)
            didLoadPersistentSnapshot = true
            viewport = TerminalCanvasViewport(
                offset: snapshot.viewport.offset,
                scale: clampedScale(snapshot.viewport.scale),
                fittedSessionId: snapshot.viewport.fittedSessionId
            )
            itemsById = snapshot.items.reduce(into: [:]) { partialResult, item in
                partialResult[item.id] = TerminalCanvasItemSnapshot(
                    id: item.id,
                    rect: sanitizedRect(item.rect),
                    workingDirectory: item.workingDirectory,
                    createdOrder: item.createdOrder
                )
            }
        } catch {
            print("[Canvas] Failed to load snapshot: \(error)")
        }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.saveSnapshot()
            }
        }
        saveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func saveSnapshot() {
        let snapshot = TerminalCanvasSnapshot(
            viewport: viewport,
            items: items
        )

        do {
            let directory = snapshotURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch {
            print("[Canvas] Failed to save snapshot: \(error)")
        }
    }

    private var snapshotURL: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
        return supportDirectory
            .appendingPathComponent("Moss", isDirectory: true)
            .appendingPathComponent("canvas-state.json")
    }

    private func sanitizedRect(_ rect: CGRect) -> CGRect {
        var rect = rect.standardized
        rect.size.width = max(TerminalCanvasMetrics.minCardSize.width, rect.width)
        rect.size.height = max(TerminalCanvasMetrics.minCardSize.height, rect.height)
        return rect
    }

    private func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(TerminalCanvasMetrics.maxScale, max(TerminalCanvasMetrics.minScale, scale))
    }

    private func snapThreshold() -> CGFloat {
        TerminalCanvasMetrics.snapThresholdScreen / max(0.1, viewport.scale)
    }

    private func snappedMoveRect(
        _ rect: CGRect,
        others: [TerminalCanvasItemSnapshot]
    ) -> CGRect {
        var rect = rect
        if let deltaX = bestMoveSnapDelta(
            movingMin: rect.minX,
            movingMax: rect.maxX,
            targetValues: xSnapTargets(others: others)
        ) {
            rect.origin.x += deltaX
        }
        if let deltaY = bestMoveSnapDelta(
            movingMin: rect.minY,
            movingMax: rect.maxY,
            targetValues: ySnapTargets(others: others)
        ) {
            rect.origin.y += deltaY
        }
        return rect
    }

    private func snappedResizeRect(
        _ rect: CGRect,
        handle: TerminalCanvasResizeHandle,
        others: [TerminalCanvasItemSnapshot]
    ) -> CGRect {
        var rect = rect
        let xTargets = xSnapTargets(others: others)
        let yTargets = ySnapTargets(others: others)

        if handle.movesMinX,
           let snapped = bestEdgeSnapValue(current: rect.minX, targets: xTargets)
        {
            let maxX = rect.maxX
            rect.origin.x = snapped
            rect.size.width = maxX - snapped
        }

        if handle.movesMaxX,
           let snapped = bestEdgeSnapValue(current: rect.maxX, targets: xTargets)
        {
            rect.size.width = snapped - rect.minX
        }

        if handle.movesMinY,
           let snapped = bestEdgeSnapValue(current: rect.minY, targets: yTargets)
        {
            let maxY = rect.maxY
            rect.origin.y = snapped
            rect.size.height = maxY - snapped
        }

        if handle.movesMaxY,
           let snapped = bestEdgeSnapValue(current: rect.maxY, targets: yTargets)
        {
            rect.size.height = snapped - rect.minY
        }

        return rect
    }

    private func clampedMoveRect(
        _ rect: CGRect,
        originalRect: CGRect,
        translation: CGSize,
        others: [TerminalCanvasItemSnapshot]
    ) -> CGRect {
        var rect = rect

        if translation.width > 0 {
            let blockers = others
                .filter { rangesOverlap(rect.minY...rect.maxY, $0.rect.minY...$0.rect.maxY) }
                .filter { originalRect.maxX <= $0.rect.minX + 0.5 }
                .filter { rect.maxX > $0.rect.minX }
            if let limit = blockers.map({ $0.rect.minX - rect.width }).min() {
                rect.origin.x = min(rect.origin.x, limit)
            }
        } else if translation.width < 0 {
            let blockers = others
                .filter { rangesOverlap(rect.minY...rect.maxY, $0.rect.minY...$0.rect.maxY) }
                .filter { originalRect.minX >= $0.rect.maxX - 0.5 }
                .filter { rect.minX < $0.rect.maxX }
            if let limit = blockers.map(\.rect.maxX).max() {
                rect.origin.x = max(rect.origin.x, limit)
            }
        }

        if translation.height > 0 {
            let blockers = others
                .filter { rangesOverlap(rect.minX...rect.maxX, $0.rect.minX...$0.rect.maxX) }
                .filter { originalRect.maxY <= $0.rect.minY + 0.5 }
                .filter { rect.maxY > $0.rect.minY }
            if let limit = blockers.map({ $0.rect.minY - rect.height }).min() {
                rect.origin.y = min(rect.origin.y, limit)
            }
        } else if translation.height < 0 {
            let blockers = others
                .filter { rangesOverlap(rect.minX...rect.maxX, $0.rect.minX...$0.rect.maxX) }
                .filter { originalRect.minY >= $0.rect.maxY - 0.5 }
                .filter { rect.minY < $0.rect.maxY }
            if let limit = blockers.map(\.rect.maxY).max() {
                rect.origin.y = max(rect.origin.y, limit)
            }
        }

        return rect
    }

    private func clampedResizeRect(
        _ rect: CGRect,
        originalRect: CGRect,
        handle: TerminalCanvasResizeHandle,
        others: [TerminalCanvasItemSnapshot]
    ) -> CGRect {
        var rect = rect

        if handle.movesMaxX {
            let blockers = others
                .filter { rangesOverlap(rect.minY...rect.maxY, $0.rect.minY...$0.rect.maxY) }
                .filter { originalRect.maxX <= $0.rect.minX + 0.5 }
                .filter { rect.maxX > $0.rect.minX }
            if let limit = blockers.map(\.rect.minX).min() {
                rect.size.width = limit - rect.minX
            }
        }

        if handle.movesMinX {
            let blockers = others
                .filter { rangesOverlap(rect.minY...rect.maxY, $0.rect.minY...$0.rect.maxY) }
                .filter { originalRect.minX >= $0.rect.maxX - 0.5 }
                .filter { rect.minX < $0.rect.maxX }
            if let limit = blockers.map(\.rect.maxX).max() {
                let maxX = rect.maxX
                rect.origin.x = limit
                rect.size.width = maxX - limit
            }
        }

        if handle.movesMaxY {
            let blockers = others
                .filter { rangesOverlap(rect.minX...rect.maxX, $0.rect.minX...$0.rect.maxX) }
                .filter { originalRect.maxY <= $0.rect.minY + 0.5 }
                .filter { rect.maxY > $0.rect.minY }
            if let limit = blockers.map(\.rect.minY).min() {
                rect.size.height = limit - rect.minY
            }
        }

        if handle.movesMinY {
            let blockers = others
                .filter { rangesOverlap(rect.minX...rect.maxX, $0.rect.minX...$0.rect.maxX) }
                .filter { originalRect.minY >= $0.rect.maxY - 0.5 }
                .filter { rect.minY < $0.rect.maxY }
            if let limit = blockers.map(\.rect.maxY).max() {
                let maxY = rect.maxY
                rect.origin.y = limit
                rect.size.height = maxY - limit
            }
        }

        return rect
    }

    private func rectWithMinimumSize(
        _ rect: CGRect,
        anchoredBy handle: TerminalCanvasResizeHandle
    ) -> CGRect {
        var rect = rect.standardized

        if rect.width < TerminalCanvasMetrics.minCardSize.width {
            if handle.movesMinX {
                rect.origin.x = rect.maxX - TerminalCanvasMetrics.minCardSize.width
            }
            rect.size.width = TerminalCanvasMetrics.minCardSize.width
        }

        if rect.height < TerminalCanvasMetrics.minCardSize.height {
            if handle.movesMinY {
                rect.origin.y = rect.maxY - TerminalCanvasMetrics.minCardSize.height
            }
            rect.size.height = TerminalCanvasMetrics.minCardSize.height
        }

        return rect
    }

    private func firstAvailableRect(
        near desiredRect: CGRect,
        excluding excludedId: UUID?
    ) -> CGRect {
        let others = items.filter { $0.id != excludedId }
        if !intersectsAny(desiredRect, others: others) {
            return sanitizedRect(desiredRect)
        }

        let step: CGFloat = 24
        let baseOrigin = desiredRect.origin

        for radius in 1...24 {
            for dx in (-radius)...radius {
                for dy in [-radius, radius] {
                    let candidate = CGRect(
                        origin: CGPoint(
                            x: baseOrigin.x + CGFloat(dx) * step,
                            y: baseOrigin.y + CGFloat(dy) * step
                        ),
                        size: desiredRect.size
                    )
                    if !intersectsAny(candidate, others: others) {
                        return sanitizedRect(candidate)
                    }
                }
            }

            if radius > 1 {
                for dy in (-(radius - 1))...(radius - 1) {
                    for dx in [-radius, radius] {
                        let candidate = CGRect(
                            origin: CGPoint(
                                x: baseOrigin.x + CGFloat(dx) * step,
                                y: baseOrigin.y + CGFloat(dy) * step
                            ),
                            size: desiredRect.size
                        )
                        if !intersectsAny(candidate, others: others) {
                            return sanitizedRect(candidate)
                        }
                    }
                }
            }
        }

        return sanitizedRect(desiredRect)
    }

    private func intersectsAny(
        _ rect: CGRect,
        others: [TerminalCanvasItemSnapshot]
    ) -> Bool {
        others.contains { $0.rect.intersects(rect) }
    }

    private func xSnapTargets(others: [TerminalCanvasItemSnapshot]) -> [CGFloat] {
        var values: [CGFloat] = []
        for item in others {
            values.append(item.rect.minX)
            values.append(item.rect.maxX)
        }
        return values
    }

    private func ySnapTargets(others: [TerminalCanvasItemSnapshot]) -> [CGFloat] {
        var values: [CGFloat] = []
        for item in others {
            values.append(item.rect.minY)
            values.append(item.rect.maxY)
        }
        return values
    }

    private func bestMoveSnapDelta(
        movingMin: CGFloat,
        movingMax: CGFloat,
        targetValues: [CGFloat]
    ) -> CGFloat? {
        let threshold = snapThreshold()
        var bestDelta: CGFloat?

        for target in targetValues {
            let candidates = [target - movingMin, target - movingMax]
            for delta in candidates where abs(delta) <= threshold {
                if let currentBestDelta = bestDelta {
                    if abs(delta) < abs(currentBestDelta) {
                        bestDelta = delta
                    }
                } else {
                    bestDelta = delta
                }
            }
        }

        return bestDelta
    }

    private func bestEdgeSnapValue(
        current: CGFloat,
        targets: [CGFloat]
    ) -> CGFloat? {
        let threshold = snapThreshold()
        var bestValue: CGFloat?
        for target in targets where abs(target - current) <= threshold {
            if let currentBestValue = bestValue {
                if abs(target - current) < abs(currentBestValue - current) {
                    bestValue = target
                }
            } else {
                bestValue = target
            }
        }
        return bestValue
    }

    private func rangesOverlap(
        _ lhs: ClosedRange<CGFloat>,
        _ rhs: ClosedRange<CGFloat>
    ) -> Bool {
        lhs.overlaps(rhs)
    }
}
