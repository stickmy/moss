import CoreGraphics
import Foundation

struct TerminalCanvasSnapshot: Codable {
    var version: Int = 1
    var viewport: TerminalCanvasViewport
    var items: [TerminalCanvasItemSnapshot]
}

struct TerminalCanvasViewport: Codable, Equatable {
    var offset: CGPoint
    var scale: CGFloat
    var fittedSessionId: UUID?

    static let `default` = TerminalCanvasViewport(
        offset: .zero,
        scale: 1.0,
        fittedSessionId: nil
    )
}

struct TerminalCanvasItemSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    var rect: CGRect
    var workingDirectory: String?
    var createdOrder: Int
    var isMinimized: Bool = false
}

struct TerminalCanvasLayoutHint {
    var preferredCenter: CGPoint?
}

enum TerminalCanvasMetrics {
    static let gridStep: CGFloat = 40
    static let snapThresholdScreen: CGFloat = 14
    static let defaultCardSize = CGSize(width: 820, height: 520)
    static let minCardSize = CGSize(width: 480, height: 320)
    static let spawnOffset = CGPoint(x: 120, y: 90)
    static let fitPadding: CGFloat = 48
    static let minScale: CGFloat = 0.1
    static let maxScale: CGFloat = 1.8

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, scale))
    }
}

enum TerminalCanvasResizeHandle: CaseIterable, Hashable {
    case north
    case south
    case east
    case west
    case northEast
    case northWest
    case southEast
    case southWest

    var movesMinX: Bool {
        switch self {
        case .west, .northWest, .southWest: true
        default: false
        }
    }

    var movesMaxX: Bool {
        switch self {
        case .east, .northEast, .southEast: true
        default: false
        }
    }

    var movesMinY: Bool {
        switch self {
        case .north, .northEast, .northWest: true
        default: false
        }
    }

    var movesMaxY: Bool {
        switch self {
        case .south, .southEast, .southWest: true
        default: false
        }
    }
}
