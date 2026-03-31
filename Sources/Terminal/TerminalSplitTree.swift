import CoreGraphics
import Foundation

enum SplitDirection {
    case horizontal // left | right
    case vertical // top / bottom
}

indirect enum TerminalSplitNode {
    case leaf(id: UUID)
    case split(direction: SplitDirection, ratio: CGFloat, first: TerminalSplitNode, second: TerminalSplitNode)
}

extension TerminalSplitNode {
    var leafId: UUID? {
        if case .leaf(let id) = self { return id }
        return nil
    }

    func allLeafIds() -> [UUID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, _, let first, let second):
            return first.allLeafIds() + second.allLeafIds()
        }
    }

    func contains(_ leafId: UUID) -> Bool {
        switch self {
        case .leaf(let id):
            return id == leafId
        case .split(_, _, let first, let second):
            return first.contains(leafId) || second.contains(leafId)
        }
    }

    /// Insert a new leaf next to the target leaf, creating a split.
    /// `newFirst`: if true, new leaf is placed first (left/top); otherwise second (right/bottom).
    func inserting(
        newLeafId: UUID,
        at targetLeafId: UUID,
        direction: SplitDirection,
        newFirst: Bool = false
    ) -> TerminalSplitNode? {
        switch self {
        case .leaf(let id):
            guard id == targetLeafId else { return nil }
            let existing = TerminalSplitNode.leaf(id: id)
            let newLeaf = TerminalSplitNode.leaf(id: newLeafId)
            if newFirst {
                return .split(direction: direction, ratio: 0.5, first: newLeaf, second: existing)
            } else {
                return .split(direction: direction, ratio: 0.5, first: existing, second: newLeaf)
            }

        case .split(let dir, let ratio, let first, let second):
            if let newFirst = first.inserting(newLeafId: newLeafId, at: targetLeafId, direction: direction, newFirst: newFirst) {
                return .split(direction: dir, ratio: ratio, first: newFirst, second: second)
            }
            if let newSecond = second.inserting(newLeafId: newLeafId, at: targetLeafId, direction: direction, newFirst: newFirst) {
                return .split(direction: dir, ratio: ratio, first: first, second: newSecond)
            }
            return nil
        }
    }

    /// Remove a leaf. Returns the remaining tree, or nil if this was the only leaf.
    func removing(_ leafId: UUID) -> TerminalSplitNode? {
        switch self {
        case .leaf(let id):
            return id == leafId ? nil : self

        case .split(let dir, let ratio, let first, let second):
            let firstContains = first.contains(leafId)
            let secondContains = second.contains(leafId)

            if !firstContains && !secondContains {
                return self
            }

            if firstContains {
                if let newFirst = first.removing(leafId) {
                    return .split(direction: dir, ratio: ratio, first: newFirst, second: second)
                }
                // first was the leaf being removed — promote second
                return second
            } else {
                if let newSecond = second.removing(leafId) {
                    return .split(direction: dir, ratio: ratio, first: first, second: newSecond)
                }
                // second was the leaf being removed — promote first
                return first
            }
        }
    }

    /// Update the ratio of a split that contains the given leaf as a direct child.
    func updatingRatio(containingLeaf leafId: UUID, newRatio: CGFloat) -> TerminalSplitNode {
        switch self {
        case .leaf:
            return self
        case .split(let dir, let ratio, let first, let second):
            // If either direct child is the target leaf, update this split's ratio
            if first.leafId == leafId || second.leafId == leafId {
                return .split(direction: dir, ratio: newRatio, first: first, second: second)
            }
            // Check if a child split directly contains both children of a split with the target
            let newFirst = first.updatingRatio(containingLeaf: leafId, newRatio: newRatio)
            let newSecond = second.updatingRatio(containingLeaf: leafId, newRatio: newRatio)
            return .split(direction: dir, ratio: ratio, first: newFirst, second: newSecond)
        }
    }

    /// Update ratio of the split node identified by the first leaf ID of its `first` child.
    func updatingRatioForSplit(firstChildLeafId: UUID, newRatio: CGFloat) -> TerminalSplitNode {
        switch self {
        case .leaf:
            return self
        case .split(let dir, let ratio, let first, let second):
            if first.allLeafIds().first == firstChildLeafId {
                let clamped = min(0.9, max(0.1, newRatio))
                return .split(direction: dir, ratio: clamped, first: first, second: second)
            }
            return .split(
                direction: dir,
                ratio: ratio,
                first: first.updatingRatioForSplit(firstChildLeafId: firstChildLeafId, newRatio: newRatio),
                second: second.updatingRatioForSplit(firstChildLeafId: firstChildLeafId, newRatio: newRatio)
            )
        }
    }
}
