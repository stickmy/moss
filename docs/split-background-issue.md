# Split Pane Background Color Inconsistency

## Problem

After splitting a terminal card (Cmd+D), the **first pane** (original) has a slightly grayish/different background compared to the **second pane** (newly created). This difference persists regardless of which pane is focused.

## User's Ghostty Config

Key settings that interact with this issue:
- `theme = claude-code-light` → background = `#faf9f5` (250, 249, 245)
- `background-opacity = 0.95` → terminal renders at 95% opacity, 5% shows through to whatever is behind
- No custom `unfocused-split-fill` or `unfocused-split-opacity`

## What Works

1. **Split mechanism**: Cmd+D correctly splits the card internally (not creating a new card)
2. **Shell preservation**: Surface view cache (`TerminalSession.surfaceViewCache`) preserves the original pane's ghostty surface + shell session across SwiftUI view hierarchy changes
3. **Overlay toggling**: The unfocused overlay correctly toggles between panes when switching focus
4. **Overlay visibility**: Using contrasting color (black for light theme, white for dark) instead of `unfocusedSplitFill` (which was same as background = invisible)

## The Background Color Issue

### Root Cause (suspected)

The MossSurfaceView uses a CAMetalLayer with:
```swift
metal.isOpaque = false
metal.backgroundColor = NSColor.clear.cgColor
```

With `background-opacity = 0.95`, the ghostty surface renders its background at 95% opacity. The remaining 5% bleeds through to the view behind the Metal layer.

The card has `.background(theme.surfaceBackground.opacity(0.96))` where `surfaceBackground = bgColor.mix(with: .black, by: 0.04)` — 4% darker than the terminal background.

When the view hierarchy changes from single-pane to split-pane layout, the compositing path for the original surface changes, producing a different blend result.

### Attempts to Fix

| Attempt | Result |
|---------|--------|
| Added `.background(theme.background)` to each leaf view | No change — the panes still look different |
| Added `.clipped()` to terminal content area | Fixed header overlap but not background |
| Added `.compositingGroup()` to leaf ZStack | Actually CAUSED background change (worse) |
| Added `zIndex(1)` to header | Fixed header being affected by overlay |
| Surface view cache in TerminalSession | Fixed shell session preservation but not background |

### Why the Difference Might Persist

The original surface's MossSurfaceView was created before the split and lived in a simple view hierarchy. After the split, SwiftUI removes it from its old superview and re-inserts it via `makeNSView` (which now returns the cached view). This re-insertion into a different AppKit view hierarchy may change:

1. **CALayer compositing**: The Metal layer's position in the layer tree changes
2. **Backing store**: The view's backing CALayer may be re-created or re-composited
3. **Content scale**: The layer's `contentsScale` might be recalculated
4. **Opacity compositing**: With `isOpaque = false`, the layer compositing depends on the superview's layer

## Architecture Reference

### Current Split View Hierarchy
```
TerminalCanvasCard
└── cardSurface (VStack)
    ├── header (zIndex: 1)
    └── TerminalSplitContentView (.clipped())
        └── SplitPaneView (GeometryReader + HStack/VStack)
            ├── TerminalSplitLeafView (pane 1)
            │   └── StableTerminalWrapper → cached MossSurfaceView
            │       └── CAMetalLayer (isOpaque: false, bgColor: clear)
            ├── SplitDivider (1px NSView)
            └── TerminalSplitLeafView (pane 2)
                └── StableTerminalWrapper → new MossSurfaceView
                    └── CAMetalLayer (isOpaque: false, bgColor: clear)
```

### Key Files
- `Sources/Views/Canvas/TerminalSplitContentView.swift` — split rendering + overlay
- `Sources/Views/Zoom/StableTerminalWrapper.swift` — NSViewRepresentable, uses session cache
- `Sources/Views/Terminal/MossSurfaceView.swift` — Metal layer setup (line 94-106)
- `Sources/Terminal/TerminalSession.swift` — surface cache + split tree management
- `Sources/Terminal/TerminalSplitTree.swift` — split tree model
- `Sources/Terminal/MossTheme.swift` — unfocusedSplitOpacity/Fill values

### Ghostty Reference
- Ghostty's unfocused overlay: `/Users/shiki/workspace/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView.swift` (lines 227-234)
- Ghostty's split tree: `/Users/shiki/workspace/ghostty/macos/Sources/Features/Splits/SplitTree.swift`
- Ghostty's config: `/Users/shiki/workspace/ghostty/macos/Sources/Ghostty/Ghostty.Config.swift` (lines 506-529)

## Ideas Not Yet Tried

1. **Set Metal layer `isOpaque = true`** and handle background-opacity differently (render bg in SwiftUI behind the metal layer)
2. **Pre-render all leaves at the card level** (flat, not nested in SplitPaneView), use GeometryReader to position them — avoids NSView re-insertion
3. **Use `layer.compositingFilter`** on the Metal layer to force consistent compositing
4. **Investigate if Ghostty has the same issue** with `background-opacity < 1` and splits — test in the official Ghostty app
5. **Add the MossSurfaceView as a sublayer** of a wrapper NSView, so the actual Metal view never moves in the hierarchy — only the wrapper moves
