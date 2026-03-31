# Editor Dropdown Cursor Issue

## Problem

文件预览面板顶部的 Editor Dropdown 下拉列表中，鼠标 hover 在行上时应该显示 pointer (小手) cursor，但实际显示的是 I-beam (编辑态) cursor。

## Root Cause

SwiftUI 的 `Text` 视图在 macOS 上会通过底层 AppKit 的 `resetCursorRects` 机制设置 I-beam cursor rect。这个设置发生在 NSView 层面，优先级高于 SwiftUI 的 `.onHover` / `.onContinuousHover` 中的 `NSCursor.push()`/`pop()` 调用。

## Attempted Fixes

### 1. `NSCursor.pointingHand.set()` on every `.active` event (original code)

```swift
.onContinuousHover { phase in
    switch phase {
    case .active:
        NSCursor.pointingHand.set()
    case .ended:
        break
    }
}
```

**Result**: Cursor flickers rapidly between I-beam and pointer — `.set()` fires on every mouse move but `resetCursorRects` keeps resetting it back.

### 2. `NSCursor.push()` / `pop()` on hover entry/exit

```swift
.onHover { hovering in
    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
}
```

**Result**: I-beam still wins. The cursor stack is overridden by AppKit's cursor rect system.

### 3. `NSViewRepresentable` overlay with `addCursorRect`

```swift
// Overlay on the Button
.overlay { PointerCursorView() }

private final class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
```

**Result**: No effect. The overlay NSView likely has zero bounds because SwiftUI doesn't guarantee frame propagation for overlay NSViewRepresentable.

### 4. `.background { PointerCursorView() }` + remove Button (use `onTapGesture`)

Removed `Button` wrapper (since `Button` + `Text` injects I-beam), replaced with `onTapGesture`. Used `.background` instead of `.overlay` with `autoresizingMask` and `viewDidMoveToWindow` invalidation.

```swift
HStack { ... }
    .onTapGesture { chooseEditor(editor) }
    .background { PointerCursorView() }

private final class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}
```

**Result**: Still shows I-beam. The SwiftUI Text's underlying NSTextField cursor rect still wins, likely because it's deeper in the view hierarchy and its cursor rect is more specific.

## Possible Next Steps

- **TrackingArea approach**: Use `NSTrackingArea` with `cursorUpdate` event type to force-set the cursor on every mouse move within the area, bypassing the cursor rect system entirely.
- **NSHostingView wrapping**: Wrap the entire dropdown popover in a custom NSView/NSPanel that overrides `resetCursorRects` for its entire bounds.
- **Replace Text with non-text view**: Use `NSAttributedString` rendered into an `Image`, or a custom `NSView` label that doesn't set I-beam cursor rects.
- **Custom NSPopover/NSMenu**: Replace the SwiftUI dropdown popover with a native `NSMenu` or `NSPopover` containing `NSMenuItem`s, which naturally show pointer cursor.
