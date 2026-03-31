import AppKit
import SwiftUI

extension View {
    /// Sets the pointing-hand cursor when hovering over this view.
    func pointerCursor() -> some View {
        self.onContinuousHover { phase in
            switch phase {
            case .active:
                NSCursor.pointingHand.push()
            case .ended:
                NSCursor.pop()
            }
        }
    }
}
