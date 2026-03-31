# Fit Viewport Overlay Inset

## Problem

FilePreviewPanel 以 `.overlay()` 的方式浮在 TerminalCanvasView 上方，不占用布局空间。当用户点击 Fit 按钮时，`fitViewport` 以整个 canvas 的几何中心对齐 terminal card，导致 card 的左侧部分被 preview panel 遮挡。

```
┌─────────┬───────────────────────────────────────┐
│ FileTree│  Canvas (GeometryReader)              │
│ 220px   │                                       │
│         │ ┌──────────┐                          │
│         │ │ Preview   │    ┌─────────────┐      │
│         │ │ Panel     │    │ Terminal    │      │
│         │ │ 500px     │    │ (fitted)    │      │
│         │ │ overlay   │    │ ← 被遮挡    │      │
│         │ └──────────┘    └─────────────┘      │
└─────────┴───────────────────────────────────────┘
```

## Solution

向 `fitViewport` 传入 `leadingInset` 参数，表示 canvas 左侧被 overlay 遮挡的像素宽度。fit 时做两件事：

1. **缩小可用宽度** — 用 `canvasWidth - leadingInset` 计算 scale，使 card 缩放后能放进可见区域。
2. **偏移视口中心** — 将 viewport offset 向左移 `leadingInset / (2 * scale)`，使 card 在屏幕上居中于可见区域而非整个 canvas。

### 数学推导

Canvas 坐标映射公式：

```
screenX = (logicalX - viewport.offsetX) * scale + canvasWidth / 2
```

无 inset 时，card 中心映射到 `canvasWidth / 2`（屏幕中心）。

有 inset `L` 时，可见区域的屏幕中心为 `(L + canvasWidth) / 2`。要让 card 中心映射到这个点：

```
(cardMidX - offsetX) * scale + canvasWidth / 2 = (canvasWidth + L) / 2
(cardMidX - offsetX) * scale = L / 2
offsetX = cardMidX - L / (2 * scale)
```

修正后的效果：

```
┌─────────┬───────────────────────────────────────┐
│ FileTree│  Canvas                               │
│         │ ┌──────────┐                          │
│         │ │ Preview   │                         │
│         │ │ Panel     │  ┌─────────────┐        │
│         │ │           │  │ Terminal    │        │
│         │ │           │  │ (fitted)    │        │
│         │ └──────────┘  └─────────────┘        │
└─────────┴───────────────────────────────────────┘
                           ↑ 居中于可见区域
```

## Inset 的计算

Preview panel 的布局参数（ContentView）：

| 值 | 来源 |
|---|---|
| Preview panel 宽度 | `.frame(width: 500)` |
| Panel 距 HStack 左边距 | `.padding(.leading, fileTreeWidth + 12)` |
| Canvas 距 HStack 左边距 | `fileTreeWidth + 11`（PaneDivider interactionWidth） |

Panel 在 canvas 上的遮挡宽度 = `(fileTreeWidth + 12 + 500) - (fileTreeWidth + 11)` = **501px**。

这个值只在 `showFileTree && selectedFile != nil` 时生效，其余情况为 0。

## 涉及文件

- `Sources/Terminal/TerminalCanvasStore.swift` — `fitViewport(to:in:leadingInset:)`
- `Sources/Views/Canvas/TerminalCanvasView.swift` — 新增 `overlayLeadingInset` 属性，透传给 store
- `Sources/MossApp/ContentView.swift` — `previewPanelOverlap` 计算遮挡宽度并传入 TerminalCanvasView
