# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

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
- `TerminalSession` — Per-terminal state: title, PWD, git branch, focus, status, file tree model. Implements `MossSurfaceViewDelegate`.
- `TerminalSessionManager` — Manages session lifecycle, IPC command routing.
- `MossTheme` — Reads colors from ghostty config via `ghostty_config_get()`, provides SwiftUI colors via environment.

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
