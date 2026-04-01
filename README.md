# Moss

Moss 是一款 macOS 终端应用，专为 **vibe coding 时的多 agent 协调与监控** 设计。它基于 [Ghostty](https://ghostty.org) 终端引擎，提供无限画布界面来管理多个终端会话——同时运行多个 Claude Code 实例时，一眼纵览所有 agent 状态，快速识别哪个需要关注。

## 安装

```bash
# 生成 Xcode 项目
xcodegen generate

# 构建
xcodebuild -project Moss.xcodeproj -scheme Moss -configuration Debug build

# 构建 CLI 工具
swift build --target MossCLI
```

## 快速上手

启动 Moss 后，你会看到一个无限画布。每个终端是画布上的一张卡片，可以自由拖动、缩放、排列。

### 画布操作

| 操作 | 方式 |
|------|------|
| 平移画布 | 在空白处拖拽，或双指滑动 |
| 缩放画布 | `⌘` + 滚轮，或双指捏合 |
| 移动终端卡片 | 拖拽卡片顶部的 header |
| 调整卡片大小 | 拖拽卡片边缘或角落 |

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘N` | 新建终端 |
| `⌘P` | Quick Open（文件搜索） |
| `⌘B` | 显示/隐藏文件树 |
| `⌘⇧↩` | 聚焦当前终端（Fit to viewport） |
| `⌘+` / `⌘=` | 画布放大 |
| `⌘-` | 画布缩小 |
| `⌘0` | 画布重置（适配所有终端） |
| `⌘Q` | 退出 |

**文件树导航：**

| 按键 | 功能 |
|------|------|
| `↑` / `↓` | 移动焦点 |
| `←` / `→` | 折叠 / 展开目录 |
| `↩` | 打开文件 |
| `Space` | 预览文件 |

**Quick Open (`⌘P`)：**

| 按键 | 功能 |
|------|------|
| 输入关键词 | 模糊搜索文件名和路径 |
| `↑` / `↓` | 上下选择 |
| `↩` | 打开选中文件 |
| `Esc` | 关闭 |

## Agent 状态系统

Moss 会追踪每个终端中 agent 的运行状态，并在卡片上用颜色指示：

| 颜色 | 状态 | 含义 |
|------|------|------|
| 🔵 蓝色 | `running` | Agent 正在执行 |
| 🟠 橙色 | `waiting` | Agent 等待用户输入（审批、回答等） |
| 🟢 绿色 | `idle` | 任务完成，终端空闲 |
| 🔴 红色 | `error` | Agent 出错 |

当 agent 进入 `waiting` 状态时，Moss 会发送 macOS 系统通知，点击通知可直接跳转到对应终端。

画布顶部的控制栏会显示各状态的终端数量汇总。

## CLI 工具 (`moss`)

Moss 提供命令行工具，用于与终端会话进行 IPC 通信。

`moss` CLI 会在 Moss.app 启动时自动安装到 `~/.local/bin/moss`（symlink 指向 app bundle 内的二进制）。无需手动安装。确保 `~/.local/bin` 在你的 `PATH` 中。

### Claude Code 集成

一键安装 Claude Code hooks，自动上报 agent 状态：

```bash
# 安装 hooks（写入 ~/.claude/settings.json）
moss hook claude install

# 卸载 hooks
moss hook claude uninstall
```

安装后，Claude Code 的以下事件会自动映射为 Moss agent 状态：

| Claude Code 事件 | Moss 状态 |
|------------------|-----------|
| `SessionStart` | `running` |
| `UserPromptSubmit` | `running` |
| `Notification`（权限/空闲提示） | `waiting` |
| `Stop` | `idle` |
| `StopFailure` | `error` |

同时会自动追踪 Claude Code 的 task 创建和完成。

### 手动控制 Agent 状态

```bash
# 设置状态
moss agent status set running
moss agent status set waiting
moss agent status set idle
moss agent status set error

# 设置自动状态（优先级低于手动状态）
moss agent status auto running

# 查询当前状态
moss agent status get
```

### Task 追踪

```bash
# 创建 task
moss agent task created <task_id> <task_subject>

# 完成 task
moss agent task completed <task_id>

# 清除所有 task
moss agent task reset
```

### Session 管理

```bash
# 开始新的 agent session
moss agent session start <session_id>
```

### Activity 摘要

```bash
# 设置当前活动描述（显示在卡片 header）
moss agent activity "Writing tests for AuthService..."

# 清除活动描述
moss agent activity ""
```

## 主题

Moss 读取 Ghostty 配置文件 (`~/.config/ghostty/config`) 中的颜色方案，自动适配亮色/暗色主题。所有 UI 元素的颜色都从 Ghostty 主题派生，保持视觉一致。

## 文件预览

- 在文件树中点击文件即可预览
- 支持 Tree-sitter 语法高亮
- 内置 Git diff 视图
- 可选择用外部编辑器打开
