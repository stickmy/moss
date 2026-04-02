# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

See `BUILD.md` for full build guide including prerequisites and troubleshooting.

```bash
xcodegen generate
xcodebuild -project Moss.xcodeproj -scheme Moss -configuration Debug build
swift build --target MossCLI
```

There are no tests or linting configured.

**SPM package resolution issue**: If you get "Unable to find module dependency" errors (e.g. `TreeSitter`), the SPM package cache is corrupted. Fix:

```bash
# Close Xcode first, then:
rm -rf Moss.xcodeproj
rm -rf ~/Library/Developer/Xcode/DerivedData/Moss-*
xcodegen generate
open Moss.xcodeproj
# Wait for "Resolving Package Graph..." to finish, then ⌘B
```

**Tree-sitter linker errors** (`Undefined symbol: _tree_sitter_xxx_external_scanner_create`): Several tree-sitter grammar packages (`tree-sitter-css`, `tree-sitter-javascript`, `tree-sitter-python`, `tree-sitter-yaml`) updated their `Package.swift` to use `FileManager.default.fileExists(atPath: "src/scanner.c")` to conditionally compile the scanner. This check uses a relative path that only works when SPM's working directory is the package root — **Xcode sets a different working directory**, so the check fails and `scanner.c` is silently excluded, causing undefined symbol errors at link time.

**Fix**: Pin these packages to revisions where `scanner.c` is unconditionally listed in `sources:` (no `fileExists` check). The pinned revisions are recorded in `project.yml`. **Do not change these packages to `branch: master`** — they will break again. If you need to update a tree-sitter grammar, first verify that the new revision's `Package.swift` does NOT use `fileExists` for scanner detection.

**YAML duplicate key trap**: `project.yml` has a single `dependencies:` key under the `Moss` target containing all SPM packages, the `MossCLI` target, and SDK frameworks. **Never add a second `dependencies:` key** — YAML silently overwrites the first with the second, dropping all SPM package references and causing "Unable to find module dependency" errors for every package.

**Updating GhosttyKit**: The vendored xcframework at `Vendor/GhosttyKit.xcframework/` contains `libghostty.a` + `ghostty.h` built from [Ghostty source](https://github.com/ghostty-org/ghostty). To update:

```bash
# Requires: zig (https://ziglang.org/download/) and a ghostty source checkout
./Vendor/build-ghostty.sh /path/to/ghostty
```

This builds universal (arm64 + x86_64) `libghostty.a` from source and updates the vendored files in-place. The `module.modulemap` renames the C module from `libghostty` to `GhosttyKit` so Swift code uses `import GhosttyKit`. Do not overwrite it when updating manually.

## Architecture

Moss is a multi-terminal macOS app that uses **libghostty's C API directly** (via vendored `GhosttyKit.xcframework` in `Vendor/`). It does NOT use the higher-level `GhosttyTerminal` Swift wrapper — all ghostty interaction goes through C functions like `ghostty_surface_key()`, `ghostty_config_get()`, etc.

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

The official Ghostty macOS app ([ghostty-org/ghostty](https://github.com/ghostty-org/ghostty)) is the primary reference for libghostty usage patterns. The C API header is at `ghostty/include/ghostty.h`.

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
