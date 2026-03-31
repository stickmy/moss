# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Generate Xcode project (required after changing project.yml or adding/removing source files)
xcodegen generate

# Build the app
xcodebuild -project Moss.xcodeproj -scheme Moss -configuration Debug build

# Build and run (app binary location)
open ~/Library/Developer/Xcode/DerivedData/Moss-*/Build/Products/Debug/Moss.app

# Build CLI tool
swift build --target MossCLI
```

There are no tests or linting configured.

## Architecture

Moss is a multi-terminal macOS app that uses **libghostty's C API directly** (via `GhosttyKit` from `libghostty-spm`). It does NOT use the higher-level `GhosttyTerminal` Swift wrapper — all ghostty interaction goes through C functions like `ghostty_surface_key()`, `ghostty_config_get()`, etc.

### Core Layers

**Terminal layer** (`Sources/Terminal/`):
- `MossTerminalApp` — Owns `ghostty_app_t` and `ghostty_config_t`. Loads `~/.config/ghostty/config` at startup. All C callbacks (wakeup, action, close, clipboard) are module-level functions that route through `MossSurfaceBridge`.
- `TerminalSession` — Per-terminal state: title, PWD, git branch, focus, agent status, file tree model. Implements `MossSurfaceViewDelegate`.
- `TerminalSessionManager` — Manages session lifecycle, IPC command routing.
- `AgentStatus` — Enum: `running`, `waiting`, `idle`, `error`, `none`. Used by TerminalSession for agent state tracking.
- `AgentNotificationManager` — macOS system notifications via `UNUserNotificationCenter`. Posts when agent enters `waiting` state; click-to-focus via `.terminalFocusRequested`.
- `MossTheme` — Reads colors from ghostty config via `ghostty_config_get()`, provides semantic colors via `@Environment(\.mossTheme)`. See **Theme System** section below.

**View layer** (`Sources/Views/`):
- `MossSurfaceView` — The core NSView. Manages CAMetalLayer, CVDisplayLink rendering loop, keyboard/mouse/IME input, and ghostty surface lifecycle. This is where all key event handling lives, including `performKeyEquivalent` (checks `ghostty_surface_key_is_binding` first) and `keyDown` (applies `ghostty_surface_key_translation_mods` for option-as-alt).
- `StableTerminalWrapper` — Thin NSViewRepresentable that creates MossSurfaceView once and never recreates it.
- `ContentView` — HStack layout with file tree + preview panel + terminal grid. Panel widths are `@State` (global, not per-session). Uses custom `PaneDivider` for resize.

**App layer** (`Sources/MossApp/`):
- `AppDelegate` creates `MossTerminalApp` and `TerminalSessionManager`.
- `ContentView` injects `MossTheme` via `.environment(\.mossTheme)`.

### Key Design Decisions

- **Raw keyCode**: `UInt32(event.keyCode)` is passed directly to ghostty — never mapped through `GHOSTTY_KEY_*` enums.
- **Callback bridge**: `MossSurfaceBridge` (class, passed as `Unmanaged` pointer) connects C callbacks back to the owning `MossSurfaceView`.
- **No splits**: Ghostty split actions (`NEW_SPLIT`, `TOGGLE_SPLIT_ZOOM`) are mapped to Moss's grid/zoom equivalents in `handleAction`.
- **Panel widths are global**: Stored as `@State` in ContentView so switching terminals doesn't reset the file tree/preview panel layout.
- **Notification-based coordination**: Terminal focus changes, zoom toggles, new terminal requests, and file tree toggles use `NotificationCenter` to avoid SwiftUI observation pitfalls (see GOTCHA.md #6).

### Reference Codebase

The official Ghostty macOS app at `/Users/shiki/workspace/ghostty/` is the primary reference for libghostty usage patterns. The C API header is at `ghostty/include/ghostty.h`.

## Known Issues

See `GOTCHA.md` for detailed SwiftUI/ghostty integration pitfalls and their fixes.

**Panel resize flicker** — Dragging PaneDivider to resize the preview panel causes terminal flicker. Current mitigation uses drag offset + onDragEnd to batch updates, but doesn't fully eliminate it. Root cause: SwiftUI re-layouts the terminal grid on sibling width changes, triggering `synchronizeMetrics` → ghostty surface resize.

## Theme System

All UI colors come from `MossTheme` (`Sources/Terminal/MossTheme.swift`). **Never hardcode colors or compute derived colors in views** — add a semantic color to `MossTheme` instead.

### How it works

`MossTheme` reads `background`, `foreground`, `background-opacity`, and palette colors from ghostty config at startup, then derives all semantic colors in `init`. It is injected via `.environment(\.mossTheme)` and is **non-optional** (falls back to `MossTheme.fallback`).

### Available semantic colors

**Base colors** (from ghostty config):
- `background`, `foreground`, `surfaceBackground`, `border`, `secondaryForeground`

**Surface hierarchy** (each level lifts further from `surfaceBackground`):
- `elevatedBackground` (+0.02) — panel headers, editor canvas, code preview bg
- `raisedBackground` (+0.04) — close button bg, card header bg
- `prominentBackground` (+0.08) — header icon bg

**Interactive states**:
- `hoverBackground` — row hover highlight (semi-transparent surface)
- `accentSubtle` — rest-state accent tint (toolbar buttons)
- `accentHover` — hover-state accent tint (toolbar/dropdown hover)

**Border hierarchy**:
- `borderSubtle` (0.5 opacity) — input field borders
- `borderMedium` (0.65) — toolbar button borders, separators
- `borderStrong` (0.9) — divider overlays, active borders

**Git status**: `gitModified`, `gitAdded`, `gitDeleted`, `gitRenamed`

**Diff (NSColor)**: `diffAdded`, `diffRemoved`, `diffHunk`

**Scroller (NSColor)**: `scrollerThumb`, `scrollerThumbHover`, `scrollerThumbActive`

**Agent status**: `agentRunning` (blue), `agentWaiting` (orange), `agentIdle` (green), `agentError` (red) + `color(for: AgentStatus)` convenience method

**Other**: `isDark`, `paletteColors[0-15]`, `backgroundOpacity`, `unfocusedSplitOpacity`, `unfocusedSplitFill`

### Rules

1. **Use `theme.xxx` directly** — the environment value is non-optional, no `??` fallbacks needed.
2. **Need a new color?** Add it to `MossTheme.init` as a computed `let` property. Don't `.mix()` or `.opacity()` inline in views.
3. **NSColor needed?** For AppKit views (diff, scroller, dropdown), add an `NSColor` property to MossTheme. Don't convert `Color → NSColor` in views.
4. **NSView subclasses** that can't read `@Environment` receive theme via parameter and may store it as `MossTheme?` (nil on init, set on first update). Use `?? .fallback` when calling `FileDiffPalette`-style static methods.
