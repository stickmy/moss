# TODO

## Completed

### [DONE] 替换 libghostty-spm 的 TerminalView，自己实现 NSView
- Created `MossTerminalApp` — manages ghostty app lifecycle directly via C API
- Created `MossSurfaceView` — single NSView handling CAMetalLayer + CVDisplayLink + keyboard + mouse + IME
- Removed dependency on `GhosttyTerminal` module entirely (only `GhosttyKit` C API used)
- Eliminated: KeyInputView overlay, Mirror reflection hack, mouse event forwarding
- Raw `UInt32(event.keyCode)` passed directly (correct behavior, matching official ghostty)

### [DONE] 环境变量注入 (per-surface)
- Uses `ghostty_surface_config_s.env_vars` for per-surface injection
- `MOSS_SOCKET_PATH` and `MOSS_SURFACE_ID` set via env_vars array in surface config
- No more process-wide `setenv()` — each surface gets its own env vars

### [DONE] PWD 追踪 via OSC 7
- Handles `GHOSTTY_ACTION_PWD` callback from ghostty (triggered by OSC 7)
- Falls back to title-based PWD parsing when OSC 7 is unavailable
- No more sync timer needed — PWD updates come via direct callback

---

## Low Priority

### 向 libghostty-spm 提 PR 修复 keyCode 映射
在 `TerminalHardwareKeyRouter.swift` 中，`buildKeyInput` 应该直接用 `UInt32(event.keyCode)` 而不是映射到 `GHOSTTY_KEY_*` enum。
（Note: This is no longer a blocker since Moss bypasses GhosttyTerminal entirely）
