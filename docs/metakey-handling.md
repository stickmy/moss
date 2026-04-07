# Modifier Key Handling in Moss

Moss uses libghostty's C API for terminal input, but the macOS event routing logic
(`performKeyEquivalent` / `keyDown` / `flagsChanged`) lives entirely in the app layer.
This document describes how modifier keys are handled, what follows the official Ghostty
macOS app, and what is Moss-specific.

Reference: `Sources/Views/Terminal/MossSurfaceView.swift`, `Sources/Views/Terminal/GhosttyInput.swift`

## Event Flow Overview

```
NSEvent arrives
    │
    ▼
performKeyEquivalent          ← Intercepts bindings and special cases
    │
    │  return false
    ▼
keyDown                       ← Normal input: interpretKeyEvents + ghostty
    │
    ▼
ghostty_surface_key()         ← libghostty processes the key
```

## performKeyEquivalent

### Moss-specific: App-level shortcuts (before binding check)

```swift
Cmd+Q               → NSApplication.shared.terminate(nil)
Cmd+Shift+Return    → toggle terminal zoom
Cmd+B               → toggle file tree panel
```

These are intercepted before any ghostty logic because:

- **Cmd+Q**: ghostty has its own `quit` binding that closes the surface but doesn't
  terminate NSApp. Moss uses SwiftUI app lifecycle, so it needs `terminate(nil)`.
- **Cmd+Shift+Return / Cmd+B**: Moss canvas features with no ghostty equivalent.

Other menu-driven shortcuts (Cmd+N, Cmd+P) are handled by the SwiftUI `CommandGroup`
menu system and don't need manual interception.

### From Ghostty: Binding → keyDown routing

```swift
if isBinding {
    self.keyDown(with: event)
    return true
}
```

Official Ghostty routes bindings through `keyDown` so they get the full input processing
pipeline (interpretKeyEvents, option-as-alt translation, correct consumed_mods).

An earlier Moss implementation sent bindings directly to `ghostty_surface_key()`, bypassing
keyDown. This broke Alt-modified bindings because `event.characters` contained macOS
Unicode dead-key output (e.g. `ñ` for Alt+N) instead of the translated character.

### From Ghostty: Special Ctrl cases

```swift
Ctrl+Return  → intercept, prevent macOS context menu equivalent
Ctrl+/       → remap to Ctrl+_, prevent macOS beep sound
```

macOS mishandles these two combinations. Ghostty intercepts them in
`performKeyEquivalent`, constructs a corrected NSEvent, and routes through `keyDown`.

### From Ghostty: Two-pass mechanism for Cmd/Ctrl events

```swift
// Pass 1: store timestamp, return false → AppKit tries menu shortcuts
// Pass 2: same timestamp → forward to keyDown
```

For non-binding Cmd/Ctrl events, the first call returns false to let AppKit attempt
menu matching. If AppKit doesn't handle it, the event comes back with the same timestamp
and is forwarded to keyDown. This ensures system menu shortcuts (Edit → Copy, etc.)
work correctly while still passing unmatched Cmd/Ctrl combos to the terminal.

### From Ghostty: Non-Cmd/Ctrl events return false

```swift
if !event.modifierFlags.contains(.command) &&
   !event.modifierFlags.contains(.control) {
    return false
}
```

Alt-only, Shift-only, and unmodified events always return false, letting AppKit route
them to `keyDown` through the normal responder chain. An earlier Moss implementation
called `super.performKeyEquivalent(with: event)` here, which caused macOS to swallow
Option+key events (interpreting them as potential menu shortcuts).

## keyDown

All logic in `keyDown` follows the official Ghostty pattern:

### Option-as-Alt translation

```swift
let translatedMods = ghostty_surface_key_translation_mods(surface, mods)
let translatedFlags = applyTranslatedMods(original: event.modifierFlags, translated: translatedMods)
```

Queries ghostty config for `macos-option-as-alt`. If active, constructs a new NSEvent
with Option stripped so `interpretKeyEvents` produces the base character (e.g. `f`
instead of `ƒ`).

### interpretKeyEvents

```swift
interpretKeyEvents([translationEvent])
```

macOS input system entry point. Handles:
- Normal character production
- IME composition (Chinese, Japanese, Korean input)
- Dead keys (accented characters)
- Control character filtering (ghostty handles Ctrl encoding internally)

### consumed_mods with translation

```swift
key.consumed_mods = mods((translationMods ?? event.modifierFlags).subtracting([.control, .command]))
```

Uses the **translated** modifier flags for `consumed_mods`, not the original event flags.
This tells ghostty which modifiers were consumed by the input system for character
production. When option-as-alt strips the Option flag, consumed_mods won't include ALT,
so ghostty knows to generate escape sequences (e.g. ESC+f) instead of treating Alt as
consumed.

### lastPerformKeyEvent reset

```swift
self.lastPerformKeyEvent = nil
```

Reset before `interpretKeyEvents` to prevent stale timestamp matches if
`interpretKeyEvents` triggers a re-dispatch through `performKeyEquivalent`.

## GhosttyInput.mods — Right-side modifier detection

### From Ghostty: Device-specific modifier masks

```swift
if rawFlags & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { raw |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
if rawFlags & UInt(NX_DEVICERCTLKEYMASK) != 0   { raw |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
if rawFlags & UInt(NX_DEVICERALTKEYMASK) != 0    { raw |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
if rawFlags & UInt(NX_DEVICERCMDKEYMASK) != 0    { raw |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
```

NSEvent.ModifierFlags only has `.option` (no left/right distinction). The `NX_DEVICE*`
masks from IOKit detect which physical key was pressed. This is required for
`macos-option-as-alt = left|right` to work — without it, ghostty can't tell which
Option key is pressed and the per-side configuration has no effect.

## flagsChanged

Current Moss implementation uses a simpler approach than official Ghostty for
press/release detection (see `GhosttyInput.isFlagPress`). Official Ghostty additionally
handles side-specific detection and skips modifier events during IME preedit state.

## Summary table

| Feature | Origin | Why |
|---|---|---|
| Cmd+Q / Cmd+Shift+Return / Cmd+B interception | Moss | App-level features ghostty doesn't have |
| Binding → self.keyDown routing | Ghostty | Ensures full input pipeline for all bindings |
| Ctrl+Return / Ctrl+/ special cases | Ghostty | Work around macOS misbehavior |
| Two-pass Cmd/Ctrl mechanism | Ghostty | Let AppKit try menu shortcuts first |
| Non-Cmd/Ctrl return false | Ghostty | Prevent macOS from swallowing Alt/plain events |
| Option-as-alt translation | Ghostty | Strip Option for interpretKeyEvents |
| consumed_mods with translation | Ghostty | Tell ghostty Alt is unconsumed → escape sequences |
| Right-side modifier detection | Ghostty | Required for per-side option-as-alt config |
| lastPerformKeyEvent reset | Ghostty | Prevent stale timestamp in re-dispatch |
