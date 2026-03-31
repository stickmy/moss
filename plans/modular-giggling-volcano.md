# Plan: Card-Internal Split (多 surface 共享一个 card)

## Context

用户希望 ghostty 的 `NEW_SPLIT` 保持分割行为，但分割后的 pane 仍属于同一个 card 实例。一个 card = 一个 `TerminalSession`，共享 header（状态指示、task 进度、放大、关闭）。之前的实现（split 创建新 card）需要回退并替换为 card 内部分割。

参考：Ghostty 原生实现使用 `SplitTree`（递归 indirect enum），`SplitView`（可拖动分隔条），`TerminalSplitTreeView`（递归渲染）。Moss 采用简化版本。

## Architecture

```
TerminalSession
├── splitRoot: TerminalSplitNode     ← 递归树结构
│   ├── .leaf(id: UUID)              ← 单个 terminal surface
│   └── .split(dir, ratio, first, second)
├── surfaces: [UUID: Weak<MossSurfaceView>]
├── activeSurfaceId: UUID?           ← 当前焦点 pane
└── title/pwd/git                    ← 来自 active surface

TerminalCanvasCard
├── header (shared chrome)
└── TerminalSplitContentView         ← 递归渲染 splitRoot
    ├── leaf → StableTerminalWrapper
    └── split → HSplit/VSplit + divider
```

## Implementation

### Step 1: Revert previous split-as-new-card

回退上一轮添加的"split 创建新 card"逻辑：

- **`MossSurfaceView.swift`**: `NEW_SPLIT` 不再发 `.terminalSplitRequested` 通知，改为调用 delegate 新方法
- **`MossSurfaceView.swift`**: 删除 `.terminalSplitRequested` notification name
- **`TerminalCanvasView.swift`**: 删除 `.terminalSplitRequested` 的 onReceive handler
- **`TerminalCanvasStore.swift`**: 删除 `splitRect()` 方法
- **`TerminalSessionManager.swift`**: 删除 `splitSession()` 方法
- **`TerminalCanvasModels.swift`**: 删除 `TerminalCanvasSplitDirection`

### Step 2: Split Tree Model

**New file: `Sources/Terminal/TerminalSplitTree.swift`**

```swift
import Foundation

enum SplitDirection: Codable {
    case horizontal  // left | right
    case vertical    // top / bottom
}

indirect enum TerminalSplitNode {
    case leaf(id: UUID)
    case split(direction: SplitDirection, ratio: CGFloat, first: TerminalSplitNode, second: TerminalSplitNode)
}
```

Operations on the tree (as TerminalSplitNode extension methods):

- `inserting(newLeafId: UUID, at targetLeafId: UUID, direction: SplitDirection) -> TerminalSplitNode?`
  — 找到 targetLeafId 的 leaf，替换为 split(target + newLeaf)，ratio=0.5
- `removing(_ leafId: UUID) -> TerminalSplitNode?`
  — 移除 leaf，sibling 提升替代 parent split。如果是根 leaf 则返回 nil
- `allLeafIds() -> [UUID]`
  — 收集所有 leaf ID
- `contains(_ leafId: UUID) -> Bool`

ghostty split direction 映射（从 `ghostty_action_split_direction_e`）：
- RIGHT/DOWN → new leaf 放在 second 位置
- LEFT/UP → new leaf 放在 first 位置

### Step 3: Delegate Protocol + MossSurfaceView

**`Sources/Views/Terminal/MossSurfaceView.swift`**:

1. Delegate protocol 添加两个方法：
```swift
func surfaceDidRequestSplit(_ direction: SplitDirection, surface: MossSurfaceView)
func surfaceDidClose(processAlive: Bool, surface: MossSurfaceView)
```
改原 `surfaceDidClose(processAlive:)` 签名，加 `surface:` 参数。

2. MossSurfaceView 添加 `leafId: UUID` 属性（init 时设置）

3. `handleAction` 中 `GHOSTTY_ACTION_NEW_SPLIT`:
```swift
case GHOSTTY_ACTION_NEW_SPLIT:
    let ghosttyDir = action.action.new_split
    let dir: SplitDirection = (ghosttyDir == GHOSTTY_SPLIT_DIRECTION_DOWN || ghosttyDir == GHOSTTY_SPLIT_DIRECTION_UP) ? .vertical : .horizontal
    delegate?.surfaceDidRequestSplit(dir, surface: self)
```

4. `handleClose` 改为传 self: `delegate?.surfaceDidClose(processAlive: processAlive, surface: self)`

### Step 4: TerminalSession 多 surface 管理

**`Sources/Terminal/TerminalSession.swift`**:

1. 替换 `weak var surfaceView: MossSurfaceView?` 为：
```swift
var splitRoot: TerminalSplitNode
private var activeSurfaceId: UUID?
```
`splitRoot` 在 init 中初始化为 `.leaf(id: initialLeafId)`，`initialLeafId` 保存为 let 属性。

2. 新增 surface 注册/查找：
```swift
// surface 通过 view hierarchy 查找，不需要 session 持有强引用
// activeSurfaceId 用于 SurfaceFocusCoordinator 匹配
```

3. 新增 split/close 方法：
```swift
func splitSurface(_ leafId: UUID, direction: SplitDirection) {
    let newLeafId = UUID()
    guard let newRoot = splitRoot.inserting(newLeafId: newLeafId, at: leafId, direction: direction) else { return }
    splitRoot = newRoot
    activeSurfaceId = newLeafId
}

func closeSurface(_ leafId: UUID) {
    guard let newRoot = splitRoot.removing(leafId) else {
        // 最后一个 leaf，关闭整个 session
        onClose?()
        NotificationCenter.default.post(name: .terminalSessionClosed, object: self)
        return
    }
    splitRoot = newRoot
    // 如果关闭的是 active surface，切换到第一个 leaf
    if activeSurfaceId == leafId {
        activeSurfaceId = newRoot.allLeafIds().first
    }
}
```

4. Delegate 实现更新：
```swift
func surfaceDidRequestSplit(_ direction: SplitDirection, surface: MossSurfaceView) {
    guard let leafId = surface.leafId else { return }
    splitSurface(leafId, direction: direction)
}

func surfaceDidClose(processAlive: Bool, surface: MossSurfaceView) {
    guard let leafId = surface.leafId else { return }
    closeSurface(leafId)
}

func surfaceDidChangeFocus(_ focused: Bool, surface: MossSurfaceView) {
    if focused, let leafId = surface.leafId {
        activeSurfaceId = leafId
    }
    isFocused = focused
}

func surfaceDidChangeTitle(_ title: String, surface: MossSurfaceView) {
    guard surface.leafId == activeSurfaceId else { return }
    // existing title logic...
}

func surfaceDidChangePwd(_ pwd: String, surface: MossSurfaceView) {
    guard surface.leafId == activeSurfaceId else { return }
    // existing pwd logic...
}
```

5. Desktop notification / acknowledge — 保持 session 级别，不需要 surface 参数。

### Step 5: StableTerminalWrapper 支持 leafId

**`Sources/Views/Zoom/StableTerminalWrapper.swift`**:

添加 `leafId: UUID` 参数。`makeNSView` 中设置 `view.leafId = leafId`。

去掉 `session.surfaceView = view`（不再使用单一 surfaceView 引用）。

### Step 6: TerminalSplitContentView

**New file: `Sources/Views/Canvas/TerminalSplitContentView.swift`**

递归渲染 session 的 split tree：

```swift
struct TerminalSplitContentView: View {
    @Bindable var session: TerminalSession

    var body: some View {
        nodeView(session.splitRoot)
    }

    @ViewBuilder
    func nodeView(_ node: TerminalSplitNode) -> some View {
        switch node {
        case .leaf(let id):
            StableTerminalWrapper(session: session, leafId: id, isActive: true)
        case .split(let direction, let ratio, let first, let second):
            SplitPaneView(direction: direction, ratio: ratio) {
                nodeView(first)
            } second: {
                nodeView(second)
            }
        }
    }
}
```

**SplitPaneView** — 简单的两面板 + 可拖拽分隔条：
```swift
struct SplitPaneView<First: View, Second: View>: View {
    let direction: SplitDirection
    let ratio: CGFloat
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    var body: some View {
        GeometryReader { geo in
            // direction == .horizontal: HStack layout
            // direction == .vertical: VStack layout
            // 中间 1px divider，可拖拽调整 ratio
        }
    }
}
```

分隔条：1px 可见线 + 6px 隐形点击区域，hover 时改变光标（↔ 或 ↕）。

### Step 7: TerminalCanvasCard 使用 TerminalSplitContentView

**`Sources/Views/Canvas/TerminalCanvasCard.swift`**:

```swift
// Before:
StableTerminalWrapper(session: session, isActive: true)

// After:
TerminalSplitContentView(session: session)
```

### Step 8: SurfaceFocusCoordinator 适配

**`Sources/Views/Canvas/SurfaceFocusCoordinator.swift`**:

当前已经遍历 view hierarchy 找 MossSurfaceView。改为：优先匹配 `activeSurfaceId`：

```swift
static func focus(_ session: TerminalSession) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        guard let window = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow else { return }
        var surfaces: [MossSurfaceView] = []
        collectSurfaceViews(in: window.contentView, into: &surfaces)
        let sessionSurfaces = surfaces.filter { $0.sessionId == session.id }
        // 优先匹配 activeSurfaceId
        if let activeId = session.activeSurfaceId,
           let target = sessionSurfaces.first(where: { $0.leafId == activeId }) {
            window.makeFirstResponder(target)
        } else if let first = sessionSurfaces.first {
            window.makeFirstResponder(first)
        }
    }
}
```

### Step 9: Split ratio 可拖拽调整

Split ratio 需要 mutable。在 `TerminalSplitNode` 上添加 `updatingRatio(at path:, ratio:)` 方法，或在 `TerminalSession` 中通过递归查找 split 节点更新 ratio。

SplitPaneView 拖拽分隔条时回调 session 更新 ratio。

## Files Changed

| File | Action |
|---|---|
| `Sources/Terminal/TerminalSplitTree.swift` | **New** — split tree model |
| `Sources/Terminal/TerminalSession.swift` | Modify — 多 surface 管理 |
| `Sources/Views/Terminal/MossSurfaceView.swift` | Modify — delegate 改签名, leafId |
| `Sources/Views/Zoom/StableTerminalWrapper.swift` | Modify — 支持 leafId |
| `Sources/Views/Canvas/TerminalSplitContentView.swift` | **New** — 递归渲染 split tree |
| `Sources/Views/Canvas/TerminalCanvasCard.swift` | Modify — 用 TerminalSplitContentView |
| `Sources/Views/Canvas/SurfaceFocusCoordinator.swift` | Modify — 匹配 activeSurfaceId |
| `Sources/Views/Canvas/TerminalCanvasView.swift` | Modify — 删除 split notification handler |
| `Sources/Terminal/TerminalCanvasStore.swift` | Modify — 删除 splitRect() |
| `Sources/Terminal/TerminalSessionManager.swift` | Modify — 删除 splitSession() |
| `Sources/Terminal/TerminalCanvasModels.swift` | Modify — 删除 TerminalCanvasSplitDirection |

## Verification

1. `xcodegen generate && xcodebuild build` — 编译通过
2. 打开 Moss，在终端中按 ghostty 分割快捷键（如 Cmd+D / Cmd+Shift+D）
3. 验证：
   - Card 不会新增，原 card 内部出现分割线
   - 两个 pane 各自有独立的 shell
   - Card header（状态指示、task 进度、关闭按钮）仍然只有一套
   - 点击不同 pane 可以切换焦点
   - Card header 的 title 随焦点 pane 变化
   - 拖拽分隔条可调整 pane 比例
   - 关闭一个 pane（shell exit）后，另一个 pane 占据全部空间
   - 关闭最后一个 pane 时，整个 card 被移除
