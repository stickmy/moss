# Moss Development Gotchas

## 1. Terminal State Lost When Switching Between Grid and Zoom

### Symptom
Switching from zoomed terminal to grid view and back causes the terminal to restart (shell history, running processes, and screen content are lost).

### Root Cause
There are two independent causes:

#### Cause A: SwiftUI Recreates NSView When View Hierarchy Changes
Using `if/else` to conditionally show/hide the grid overlay changes the ZStack's children count. SwiftUI may then recreate sibling `NSViewRepresentable` views (the terminal surfaces), which triggers `AppTerminalView.viewDidMoveToWindow()` → `freeSurface()` → shell process killed.

**Fix:** Always keep the grid view mounted. Use `.opacity(0/1)` instead of `if/else`:
```swift
// BAD: changes ZStack child count, triggers NSView recreation
if zoomedSession == nil { GridView(...) }

// GOOD: stable ZStack structure
GridView(...).opacity(zoomedSession == nil ? 1 : 0)
```

#### Cause B: SwiftUI's TerminalSurfaceView Gets Recreated on State Changes
Even with opacity, SwiftUI's `NSViewRepresentable` may recreate the underlying `NSView` when the containing view's body is re-evaluated. The library's `TerminalViewRepresentable` creates a new `AppTerminalView` each time `makeNSView` is called, and the old surface is destroyed when `viewDidMoveToWindow` fires with `window == nil`.

**Fix:** Use a custom `NSViewRepresentable` (`StableTerminalWrapper`) that directly creates and holds the `TerminalView` (AppTerminalView). This gives us full control over the NSView lifecycle:
```swift
struct StableTerminalWrapper: NSViewRepresentable {
    func makeNSView(context: Context) -> StableTerminalContainer {
        // Created once, never recreated
        StableTerminalContainer(terminalState: session.terminalState)
    }
    func updateNSView(_ nsView: StableTerminalContainer, context: Context) {
        // Only toggle visibility, never recreate
        nsView.alphaValue = isZoomed ? 1 : 0
    }
}
```

### Verification
Add `NSLog` in `makeNSView` — it should only fire once per session, never on zoom/grid switches. `updateNSView` should fire on every toggle but must NOT recreate the terminal view.

---

## 2. Terminal Input Not Working (Focus Issue)

### Symptom
Terminal renders correctly but keyboard input is ignored.

### Root Cause
The `AppTerminalView` (NSView) needs to be the window's first responder to receive key events. SwiftUI doesn't automatically set first responder for `NSViewRepresentable` views.

With multiple terminals in a ZStack (only one visible via opacity), we must focus the *correct* one — the one whose ancestor chain has `alphaValue > 0`.

### Fix
Walk the NSView hierarchy to find all `TerminalView` instances, check effective visibility, and `makeFirstResponder` on the visible one:
```swift
private func focusVisibleTerminal() {
    var allTerminals: [NSView] = []
    collectTerminalViews(in: window.contentView, into: &allTerminals)
    for tv in allTerminals {
        if isEffectivelyVisible(tv) {
            window.makeFirstResponder(tv)
            return
        }
    }
}

private func isEffectivelyVisible(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let v = current {
        if v.alphaValue < 0.01 { return false }
        current = v.superview
    }
    return true
}
```

Trigger this on every `zoomedSession` change with a small delay (0.15s) to let SwiftUI update the view hierarchy first.

---

## 3. Delete Key Not Working

### Symptom
Backspace/delete key doesn't delete characters in the terminal.

### Root Cause
`libghostty-spm`'s `TerminalController` loads config via `ghostty_config_load_file()` with a generated temp file, instead of calling `ghostty_config_load_default_files()` which loads ghostty's built-in defaults (including default keybindings). This may cause some default keybinds to be missing.

### Fix
Explicitly add keybindings in the `TerminalController` configuration:
```swift
let controller = TerminalController { builder in
    builder.withCustom("keybind", "backspace=text:\\x7f")
    builder.withCustom("keybind", "delete=text:\\x1b[3~")
}
```

---

## 4. Two TerminalSurfaceViews Sharing Same TerminalViewState = Snow/Static

### Symptom
Terminal shows black/white noise (TV static) instead of normal content.

### Root Cause
If two `TerminalSurfaceView` instances reference the same `TerminalViewState`, two `AppTerminalView` NSViews are created, both trying to own the same ghostty surface. This causes rendering corruption.

### Fix
Ensure each `TerminalViewState` has exactly ONE corresponding view in the hierarchy at any time. Use opacity to show/hide rather than conditional rendering that could create duplicates.

---

## 5. Phantom Selection / Ghost Drag When Switching Terminals

### Symptom
Clicking a terminal to focus it causes unwanted text selection (phantom drag). Moving the mouse over the previously focused terminal extends a selection that shouldn't exist. Same issue as [ghostty PR #11276](https://github.com/ghostty-org/ghostty/pull/11276).

### Root Cause
Two independent causes:

#### Cause A: Focus-click forwarded to ghostty surface
When clicking an unfocused terminal, `mouseDown` sends `GHOSTTY_MOUSE_PRESS` to the surface, starting a selection. The click was only meant to focus the terminal, not interact with content.

#### Cause B: Mouse position events sent to unfocused surfaces
Both terminals have active NSTrackingAreas (`.activeInKeyWindow`). When the mouse moves over the unfocused terminal, `mouseMoved` sends position updates to its ghostty surface. If the surface has any stale mouse-button-down state, it interprets movement as a drag, creating phantom selections.

### Fix
Three layers of defense in `MossSurfaceView`:

1. **Focus-click suppression** — Track `focusClickSuppressed` flag. In `mouseDown`, if the view wasn't already first responder, set the flag and don't send PRESS to ghostty. Skip RELEASE and DRAG too while flag is set.

2. **Mouse events only for focused surface** — Guard `mouseMoved`, `mouseDragged`, and `scrollWheel` with `window?.firstResponder === self`. Unfocused surfaces receive no position updates.

3. **Reset on focus loss** — In `resignFirstResponder`, reset `focusClickSuppressed = false` (prevents stale state, same fix as ghostty PR #11276) and send `GHOSTTY_MOUSE_RELEASE` to clear any lingering button-down state.

```swift
override func mouseDown(with event: NSEvent) {
    let wasFocused = window?.firstResponder === self
    window?.makeFirstResponder(self)
    if !wasFocused {
        focusClickSuppressed = true
        return  // Don't send to ghostty
    }
    // ... normal handling
}

override func mouseMoved(with event: NSEvent) {
    guard let surface, window?.firstResponder === self else { return }
    // ... only forward to focused surface
}

override func resignFirstResponder() -> Bool {
    focusClickSuppressed = false  // Reset stale state
    ghostty_surface_mouse_button(surface, RELEASE, LEFT, NONE)
    ghostty_surface_set_focus(surface, false)
    // ...
}
```

---

## 6. File Tree Doesn't Switch on Every Terminal Focus Change

### Symptom
With two terminals A and B and file tree open: clicking A→B doesn't update the file tree, but A→B→A→B does (skips every other switch).

### Root Cause
Using `onChange(of: focusedSession?.id)` to track which session's file tree to show. `focusedSession` is a computed property that reads `session.isFocused` from @Observable sessions. When switching focus, `resignFirstResponder` sets A.isFocused=false and `becomeFirstResponder` sets B.isFocused=true within the same event. SwiftUI's observation may coalesce or produce intermediate nil states, causing `onChange` to fire inconsistently.

### Fix
Use `NotificationCenter` instead of `onChange` on a computed property. Post `.terminalFocusChanged` directly from `becomeFirstResponder` with the session ID. ContentView receives it via `onReceive` and sets `fileTreeSession` immediately — no computed property chain, no intermediate states.

```swift
// MossSurfaceView.becomeFirstResponder
NotificationCenter.default.post(
    name: .terminalFocusChanged,
    object: nil,
    userInfo: ["sessionId": sessionId]
)

// ContentView
.onReceive(NotificationCenter.default.publisher(for: .terminalFocusChanged)) { notif in
    if let id = notif.userInfo?["sessionId"] as? UUID,
       let s = sessionManager.sessions.first(where: { $0.id == id }) {
        fileTreeSession = s
    }
}
```

This also naturally ignores focus-loss events (clicking the file tree itself doesn't post the notification), so the file tree stays stable when interacting with it.

---

## 7. Pointer Cursor on Buttons — NSViewRepresentable Overlay Approaches All Fail

### Symptom
Buttons need a pointing-hand cursor on hover. The naive `onHover` + `NSCursor.push()/pop()` approach can cause cursor stack imbalances (e.g., if the view is removed while hovered, `pop()` never fires).

### Failed Approaches

All NSViewRepresentable-based approaches were tried and failed:

1. **`.overlay { PointerCursorView() }`** — NSView sits on top, cursor rects work, but **blocks all click events** (SwiftUI's hit testing finds the NSView first and never delivers the event to the button underneath).

2. **`.overlay` + `hitTest(_:)` returns `nil`** — Clicks pass through, but **cursor rects stop working**. AppKit's cursor rect machinery apparently skips views that return nil from hitTest, despite docs suggesting they're independent systems.

3. **`.background { PointerCursorView() }`** — Clicks work, cursor works on views without an NSView behind them (e.g., canvas controls). But **fails over terminal surfaces and code previews** — the foreground NSView's cursor rects (I-beam) take precedence over the background NSView's cursor rects.

4. **`.overlay` + `.allowsHitTesting(false)` (SwiftUI modifier)** — **Crashes the app** with `EXC_BREAKPOINT` in `ViewLayoutEngine.explicitAlignment`. Applying `.allowsHitTesting(false)` to an NSViewRepresentable confuses SwiftUI's layout engine.

### Fix
Use pure SwiftUI `onContinuousHover` — no NSView involved:

```swift
extension View {
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
```

This works because:
- No NSView overlay → no hit testing conflict → clicks always reach buttons
- `onContinuousHover` reliably provides `.active`/`.ended` phases
- SwiftUI fires `.ended` when the view is removed from the hierarchy, preventing cursor stack imbalance
- Works everywhere regardless of underlying NSView layers (terminal, code preview, etc.)

### Why not `pointerStyle(.link)` (macOS 15+)?

Apple's `pointerStyle` is the intended pointer API (WWDC24), but it has significant limitations on macOS:
- **Only works on native interactive controls** (`Button`, etc.) — views using `.onTapGesture` don't get the cursor change
- **Doesn't work in certain overlay contexts** (e.g., popover-style dropdowns positioned via `.offset()`)

Until `pointerStyle` coverage improves, `onContinuousHover` is the pragmatic choice for a universal `.pointerCursor()` modifier.

### References

- [Apple HIG — Pointing devices](https://developer.apple.com/design/human-interface-guidelines/pointing-devices)
- [WWDC24 — What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2024/10144/)
- [Apple Cocoa Event Handling Guide — Using Tracking-Area Objects](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html)
