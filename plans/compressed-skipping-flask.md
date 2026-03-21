# Moss - Multi-Terminal Application Plan

## Context

Build a macOS-native multi-terminal application ("moss") powered by libghostty with:
- Grid overview of all terminals, click-to-zoom any terminal to fullscreen
- Per-terminal status (running/pending/none) with animated visual effects, controlled via CLI
- Status bar per terminal (CWD, git branch, status)
- Per-terminal file tree panel (docked/floating, with search, file preview, diff mode)

## Architecture: Swift + SwiftUI + AppKit + GhosttyKit.xcframework

Following the proven pattern of Ghostty's own macOS app and Supacode. Key insight: use `libghostty-spm` (prebuilt GhosttyKit.xcframework as Swift Package) for easy integration.

### Reference Code Studied
- `/Users/shiki/workspace/ghostty/include/ghostty.h` — Full C API (1177 lines)
- `/Users/shiki/workspace/ghostty/macos/Sources/Ghostty/Ghostty.App.swift` — Runtime init pattern
- `/Users/shiki/workspace/ghostty/macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` — NSView hosting Metal surface
- `/Users/shiki/workspace/supacode/supacode/Infrastructure/Ghostty/GhosttyRuntime.swift` — Clean runtime wrapper (simpler than Ghostty's own)
- `/Users/shiki/workspace/supacode/supacode/Infrastructure/Ghostty/GhosttySurfaceView.swift` — Surface view pattern
- `/Users/shiki/workspace/cmux/Sources/TerminalController.swift` — Unix domain socket IPC for CLI
- `/Users/shiki/workspace/cmux/CLI/cmux.swift` — CLI tool socket client pattern

---

## Project Structure

```
moss/
├── Package.swift                          # SPM with GhosttyKit dependency
├── Sources/
│   ├── MossApp/
│   │   ├── MossApp.swift                  # @main, app lifecycle
│   │   ├── AppDelegate.swift              # NSApplicationDelegate, ghostty runtime owner
│   │   └── ContentView.swift              # Root view: grid or zoomed terminal
│   │
│   ├── Ghostty/                           # libghostty integration layer
│   │   ├── GhosttyRuntime.swift           # Wraps ghostty_app_t + runtime callbacks
│   │   ├── GhosttySurfaceView.swift       # NSView subclass hosting Metal terminal
│   │   ├── GhosttySurfaceBridge.swift     # Observable bridge: title, pwd, cellSize
│   │   └── GhosttyConfig.swift            # Config loading wrapper
│   │
│   ├── Terminal/                           # Terminal session management
│   │   ├── TerminalSession.swift           # Per-terminal model: surface + status + metadata
│   │   ├── TerminalSessionManager.swift    # Manages all sessions, add/remove
│   │   └── TerminalStatus.swift            # enum: running, pending, none
│   │
│   ├── Views/
│   │   ├── Grid/
│   │   │   ├── GridView.swift             # Tiled grid of all terminals
│   │   │   ├── GridCell.swift             # Single cell: border + status bar + terminal
│   │   │   └── StatusBorder.swift         # Animated border overlay per status
│   │   │
│   │   ├── Zoom/
│   │   │   └── ZoomedTerminalView.swift   # Fullscreen single terminal
│   │   │
│   │   ├── StatusBar/
│   │   │   └── TerminalStatusBar.swift    # CWD, git branch, status indicator
│   │   │
│   │   └── FileTree/
│   │       ├── FileTreeView.swift         # File tree with search
│   │       ├── FileTreeModel.swift        # Directory scanning, lazy loading
│   │       ├── FilePreviewView.swift       # File content viewer
│   │       └── FileDiffView.swift         # Git diff viewer
│   │
│   ├── IPC/
│   │   ├── SocketServer.swift             # Unix domain socket listener
│   │   ├── SocketProtocol.swift           # JSON command definitions
│   │   └── IPCRouter.swift                # Routes commands to sessions
│   │
│   └── Helpers/
│       ├── GitHelper.swift                # Git branch/diff detection
│       └── AnimatedBorder.swift           # Reusable conic gradient border animation
│
├── Sources/MossCLI/
│   ├── main.swift                         # `moss` CLI entry point (subcommands: status)
│   └── SocketClient.swift                 # Connects to app via Unix socket
│
└── Resources/
    └── shell-integration/                 # Shell hooks for CWD/status reporting
```

## Build System

```swift
// Package.swift
import PackageDescription

let package = Package(
    name: "Moss",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "moss", targets: ["MossCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MossApp",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
            ]
        ),
        .executableTarget(
            name: "MossCLI"
        ),
    ]
)
```

Note: The main app will also need an Xcode project for proper .app bundle, entitlements, and Info.plist. SPM manages dependencies; Xcode handles app packaging. (Same pattern as Supacode.)

---

## Core Implementation Details

### 1. GhosttyRuntime (based on Supacode's cleaner pattern)

```swift
// Single instance, owned by AppDelegate
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?

    init() {
        let config = ghostty_config_new()
        ghostty_config_load_default_files(config)
        ghostty_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in ... },
            action_cb: { app, target, action in ... },
            read_clipboard_cb: { ... },
            confirm_read_clipboard_cb: { ... },
            write_clipboard_cb: { ... },
            close_surface_cb: { ... }
        )
        self.app = ghostty_app_new(&runtimeConfig, config)
    }

    func tick() { ghostty_app_tick(app) }
}
```

The `action_cb` is critical — it receives events from libghostty including:
- `GHOSTTY_ACTION_PWD` — working directory changes (→ update status bar)
- `GHOSTTY_ACTION_SET_TITLE` — terminal title changes
- `GHOSTTY_ACTION_CELL_SIZE` — cell size for proper rendering
- `GHOSTTY_ACTION_RENDER` — trigger redraw
- `GHOSTTY_ACTION_CLOSE_WINDOW` — terminal closed

### 2. GhosttySurfaceView (NSView hosting Metal)

```swift
final class GhosttySurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?

    init(runtime: GhosttyRuntime, workingDirectory: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.wantsLayer = true  // CAMetalLayer is set up by libghostty

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
        surfaceConfig.userdata = Unmanaged.passUnretained(self).toOpaque()

        if let wd = workingDirectory {
            // Set working directory via C string
        }

        self.surface = ghostty_surface_new(runtime.app, &surfaceConfig)
    }

    // Forward all keyboard/mouse events to ghostty_surface_key/mouse/etc.
    override func keyDown(with event: NSEvent) { ... }
    override func mouseDown(with event: NSEvent) { ... }
    override func scrollWheel(with event: NSEvent) { ... }
    // ... implements NSTextInputClient for IME
}
```

### 3. TerminalSession Model

```swift
@Observable
class TerminalSession: Identifiable {
    let id = UUID()
    var status: TerminalStatus = .none
    var workingDirectory: String = "~"
    var gitBranch: String?
    var title: String = ""
    let surfaceView: GhosttySurfaceView

    // Updated by action_cb when GHOSTTY_ACTION_PWD fires
    // Updated by IPC when moss-status CLI sends commands
}

enum TerminalStatus {
    case running    // Animated spinning border
    case pending    // Orange static border
    case none       // No special border
}
```

### 4. Grid View + Zoom

```swift
struct ContentView: View {
    @State private var zoomedSession: TerminalSession?
    @Bindable var sessionManager: TerminalSessionManager

    var body: some View {
        ZStack {
            // Grid always rendered (for smooth transitions)
            GridView(sessions: sessionManager.sessions) { session in
                zoomedSession = session
            }
            .opacity(zoomedSession == nil ? 1 : 0)

            // Zoomed view overlays
            if let session = zoomedSession {
                ZoomedTerminalView(session: session) {
                    zoomedSession = nil
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: zoomedSession?.id)
    }
}

struct GridView: View {
    let sessions: [TerminalSession]
    let onTap: (TerminalSession) -> Void

    var body: some View {
        // Auto-adapt: 1=1col, 2=2col, 3-4=2x2, 5-6=3x2, 7-9=3x3, etc.
        let columns = adaptiveColumns(for: sessions.count)
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(sessions) { session in
                GridCell(session: session)
                    .onTapGesture { onTap(session) }
            }
        }
    }

    private func adaptiveColumns(for count: Int) -> [GridItem] {
        let cols = count <= 1 ? 1 : count <= 2 ? 2 : count <= 4 ? 2 : count <= 9 ? 3 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 4), count: cols)
    }
}
```

### 5. Animated Status Border

```swift
struct StatusBorder: View {
    let status: TerminalStatus
    @State private var rotation: Double = 0

    var body: some View {
        switch status {
        case .running:
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    AngularGradient(
                        colors: [.blue, .cyan, .blue.opacity(0.3), .blue],
                        center: .center,
                        angle: .degrees(rotation)
                    ),
                    lineWidth: 3
                )
                .onAppear {
                    withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }
        case .pending:
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange, lineWidth: 3)
        case .none:
            EmptyView()
        }
    }
}
```

### 6. IPC via Unix Domain Socket

**App side (SocketServer):**
- Creates socket at `$TMPDIR/moss-{pid}.sock`
- Sets `MOSS_SOCKET_PATH` env var in each terminal's PTY environment
- Sets `MOSS_SURFACE_ID` env var to the session UUID
- Listens for JSON commands, routes to TerminalSessionManager

**CLI tool (`moss status`):**
```bash
# Usage (subcommand of moss CLI)
moss status set running
moss status set pending
moss status set none
```

**Protocol (newline-delimited JSON):**
```json
{"surface_id": "uuid", "command": "set_status", "value": "running"}
```

The CLI reads `MOSS_SOCKET_PATH` and `MOSS_SURFACE_ID` from its environment (inherited from the terminal), connects to the Unix socket, sends the command, reads the response.

### 7. Status Bar

```swift
struct TerminalStatusBar: View {
    @Bindable var session: TerminalSession

    var body: some View {
        HStack(spacing: 8) {
            // CWD (from GHOSTTY_ACTION_PWD callback)
            Label(session.workingDirectory.abbreviatingWithTildeInPath,
                  systemImage: "folder")
                .font(.caption)

            // Git branch (from periodic git rev-parse)
            if let branch = session.gitBranch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
            }

            Spacer()

            // Status indicator
            StatusIndicator(status: session.status)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
    }
}
```

Git branch detection: Run `git rev-parse --abbrev-ref HEAD` when CWD changes. Use a `FileSystemWatcher` (DispatchSource) on `.git/HEAD` for live updates.

### 8. File Tree Panel

```swift
struct FileTreePanel: View {
    @Bindable var session: TerminalSession
    @State private var searchText = ""
    @State private var selectedFile: URL?
    @State private var showDiff = false

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            TextField("Search files...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            // File tree
            List(filteredTree, children: \.children) { node in
                FileTreeRow(node: node)
                    .onTapGesture {
                        if !node.isDirectory {
                            selectedFile = node.url
                        }
                    }
            }

            // File preview (when a file is selected)
            if let file = selectedFile {
                Divider()
                FilePreviewView(url: file, showDiff: showDiff)
                    .frame(height: 300)
            }
        }
    }
}
```

**Docked vs Floating:**
- Docked: `HSplitView` containing terminal + file tree
- Floating: `.popover()` or separate `NSPanel` window
- Toggle via keyboard shortcut (Cmd+B for docked, Cmd+Shift+B for float)

**Diff mode:** Run `git diff -- <file>` and parse the output, or use `git diff HEAD -- <file>` for staged+unstaged changes.

### 9. Key Bindings

| Shortcut | Action |
|----------|--------|
| Cmd+Enter | Toggle zoom (grid <-> fullscreen) |
| Cmd+N | New terminal |
| Cmd+W | Close terminal |
| Cmd+B | Toggle file tree (docked) |
| Cmd+Shift+B | Toggle file tree (floating) |
| Cmd+F | Search in file tree |
| Cmd+D | Toggle diff mode in file preview |
| Cmd+1-9 | Focus terminal N |
| Escape | Back to grid (when zoomed) |

---

## Implementation Phases

### Phase 1: Skeleton + libghostty integration
1. Create Xcode project with SPM dependency on libghostty-spm
2. Implement `GhosttyRuntime` — init app, tick loop, action callbacks
3. Implement `GhosttySurfaceView` — NSView with Metal, keyboard/mouse forwarding
4. Wrap in SwiftUI via `NSViewRepresentable`
5. Get a single working terminal rendering on screen (app starts with 1 terminal)

### Phase 2: Multi-terminal grid
1. `TerminalSession` model + `TerminalSessionManager`
2. `GridView` with auto-adaptive `LazyVGrid` layout (1→1col, 2→2col, 3-4→2x2, 5-6→3x2, etc.)
3. Click-to-zoom with animated transition
4. Cmd+N to add terminals, Cmd+W to close

### Phase 3: Status system + IPC
1. `TerminalStatus` enum with `StatusBorder` animated view
2. `SocketServer` Unix domain socket listener
3. `moss` CLI tool with `status` subcommand (`moss status set running`)
4. Wire up env vars (`MOSS_SOCKET_PATH`, `MOSS_SURFACE_ID`)

### Phase 4: Status bar
1. `TerminalStatusBar` view
2. CWD tracking via `GHOSTTY_ACTION_PWD`
3. Git branch detection with `.git/HEAD` watcher
4. Status indicator display

### Phase 5: File tree
1. `FileTreeModel` with lazy directory scanning
2. `FileTreeView` with search filtering
3. Docked mode (HSplitView) + floating mode (NSPanel)
4. `FilePreviewView` with syntax highlighting
5. `FileDiffView` with git diff parsing

---

## Verification

1. **Phase 1 test:** Launch app, type commands in terminal, verify rendering + input works
2. **Phase 2 test:** Create 4+ terminals, verify grid layout, click to zoom, Escape to return
3. **Phase 3 test:** In a terminal, run `moss status set running`, verify animated border appears. Run `moss status set pending`, verify orange border. Run `moss status set none`, verify border disappears.
4. **Phase 4 test:** `cd` to different directories, verify status bar updates. Check git repos show branch name.
5. **Phase 5 test:** Cmd+B to open file tree, navigate directories, click a file to preview, toggle diff mode with Cmd+D.
