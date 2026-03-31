import AppKit
import SwiftUI

@MainActor
final class ThemedOverlayScroller: NSScroller {
    private var thumbColor = NSColor.white.withAlphaComponent(0.16)
    private var hoverThumbColor = NSColor.white.withAlphaComponent(0.24)
    private var activeThumbColor = NSColor.white.withAlphaComponent(0.32)
    private var isHovered = false
    private var isPressed = false
    private var hoverTrackingArea: NSTrackingArea?

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        10
    }

    override class var isCompatibleWithOverlayScrollers: Bool {
        true
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard !knobRect.isEmpty else { return }

        currentThumbColor.setFill()
        NSBezierPath(rect: knobRect).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
        super.mouseDown(with: event)
        isPressed = false
        needsDisplay = true
    }

    func applyTheme(_ theme: MossTheme?) {
        guard let theme else { return }
        thumbColor = theme.scrollerThumb
        hoverThumbColor = theme.scrollerThumbHover
        activeThumbColor = theme.scrollerThumbActive
        needsDisplay = true
    }

    private var currentThumbColor: NSColor {
        if isPressed {
            return activeThumbColor
        }
        if isHovered {
            return hoverThumbColor
        }
        return thumbColor
    }
}
