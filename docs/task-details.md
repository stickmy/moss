基于当前的架构（Canvas 卡片布局 + header 进度条），几种可行的交互方案：

---

### 方案 1: Progress Indicator 点击展开 Popover

点击 header 中的进度方块，弹出一个轻量 popover 列表，显示每个 task 的 subject 和完成状态。

- **优点**：不占用额外空间，按需查看，实现简单（SwiftUI `.popover`）
- **缺点**：需要主动点击才能看到，信息不够 glanceable

---

### 方案 2: Header 下方展开 Task 抽屉

在 terminal header 和 surface 之间插入一个可折叠区域，展开时显示 task 列表（类似 IDE 的 problems panel）。点击 progress indicator 切换展开/收起。

```
┌─ Header ─────────────────────────┐
│ [•] [██░░] 2/4  │  [Fit] [Close] │
├─ Task Drawer (展开时) ───────────┤
│ ✓ Read the configuration file    │
│ ✓ Parse the AST                  │
│ ○ Implement the transform        │
│ ○ Write tests                    │
├──────────────────────────────────┤
│ Terminal surface...              │
└──────────────────────────────────┘
```

- **优点**：信息层级清晰，不遮挡终端内容，可以一直展开
- **缺点**：展开时压缩终端高度，会触发 ghostty surface resize

---

### 方案 3: Terminal Surface 上的 HUD Overlay

在终端内容上方叠加一个半透明的浮层，固定在右上角或底部，实时显示当前正在进行的 task。类似游戏里的任务追踪器。

```
┌─ Header ─────────────────────────┐
├──────────────────────────────────┤
│ Terminal surface...              │
│                    ┌────────────┐│
│                    │ ○ Implement││
│                    │ ○ Write... ││
│                    └────────────┘│
└──────────────────────────────────┘
```

- **优点**：始终可见，不影响布局，不触发 resize
- **缺点**：遮挡终端输出，对于长 subject 文字截断问题

---

### 方案 4: 当前 Task 内联到 Header

Header 中直接显示当前进行中的第一个 task subject（截断），进度方块保持不变。hover 时 tooltip 显示完整列表。

```
┌─ Header ─────────────────────────────────┐
│ [•] [██░░] Implement the transform...    │
└──────────────────────────────────────────┘
```

- **优点**：零交互成本，最 glanceable，改动最小
- **缺点**：只能显示一条，header 空间有限

---

### 我的推荐：方案 4 + 方案 1 组合

- **默认状态**：Header 中 progress indicator 旁边直接显示当前 task 的 subject（单行截断）
- **点击展开**：点击 progress 区域弹出 popover，显示完整 task 列表

这样兼顾了 glanceability（不用交互就能看到当前在做什么）和完整信息（点击查看全部）。改动也最小——不涉及 terminal surface resize，不遮挡终端内容。

你倾向哪个方向？
