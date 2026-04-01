# Feature Roadmap

Moss 的核心场景是 **vibe coding 时的多 agent 协调与监控**：同时运行多个终端 agent（如多个 Claude Code 实例），需要一眼纵览所有 agent 状态，快速识别哪个需要关注。

以下功能按优先级分层，围绕这个核心场景展开。

---

## P0 — 核心：解决"我该看哪个终端"

### 1. 丰富 Agent 状态感知

当前状态只有 `pending | none`，无法区分 agent 在做什么。需要扩展为：

| 状态 | 含义 | 视觉信号 |
|------|------|----------|
| `running` | agent 正在执行 | 默认状态，无特殊标记 |
| `waiting_for_input` | agent 在等用户操作（审批、回答） | 高亮边框 + 动画 |
| `idle` | 任务完成，终端空闲 | 淡化显示 |
| `error` | agent 出错/崩溃 | 红色标记 |

**实现要点：**
- 扩展 `TerminalStatus` 枚举
- 利用 Claude Code 的 hook 事件（`Notification`、tool use 等）上报状态
- 每种状态对应不同颜色/图标/边框样式，扫一眼画布即可分辨

### 2. 全局状态总览栏

画布顶部或侧边加一个摘要条：

```
● 2 waiting  ● 3 running  ● 1 idle
```

- 点击某个状态类别可快速跳转到对应终端
- 当有 6+ 个终端时，避免逐个去看
- 融入现有 canvas 控制栏（缩放按钮旁）

### 3. 系统级通知

当前 desktop notification 只修改卡片边框颜色——离开 Moss 窗口就看不到。需要：

- **macOS 原生通知**（`UNUserNotificationCenter`），点击直接跳转到对应终端
- **可选声音提示**
- **Dock 角标**（显示等待中的 agent 数量）
- 可配置：哪些状态触发通知，避免打扰

---

## P1 — 提升多 agent 协调效率

### 4. 智能注意力路由

- 卡片上显示等待时长（"waiting 2m"），帮助优先处理
- 可选：agent 进入 waiting 状态时自动平移视口

### 5. Agent 动态摘要

卡片 header 显示一行 agent 当前动态，不聚焦也能判断是否需要干预：

```
"Writing tests for AuthService..."
"Waiting: approve file edit?"
"Reading src/components/..."
```

- 从 Claude Code 的 task subject 或 tool call 信息中提取
- 截断显示，hover 查看完整内容

### 6. 快捷审批操作

很多时候 agent 只需要一个 "y" 确认。在卡片上加快捷操作：

- 一键发送常用响应（approve / reject / skip）
- 不用先聚焦终端 → 找输入位置 → 打字
- 减少操作步骤，加速流转

---

## P2 — 工作流增强

### 7. 会话模板 / 批量启动

保存和恢复工作阵型：

- 每个终端的初始目录、画布位置
- 一键恢复，不用每次手动开 N 个终端

### 8. 终端分组 / 标签

- 给终端打标签或分组（"frontend"、"backend"、"infra"）
- 画布上用颜色或区域区分
- 支持按组折叠/展开，管理大量终端

### 9. 活动时间线

可折叠侧边面板，按时间线展示所有 agent 关键事件：

```
14:02  Terminal 3  ✅ Task "fix auth bug" completed
14:03  Terminal 1  ⏳ Waiting for input
14:05  Terminal 2  📋 Task "add tests" created
```

- 事后回顾：离开后回来快速了解发生了什么
- 可按终端/状态筛选

---

## 优先级总表

| 优先级 | 功能 | 核心价值 |
|--------|------|----------|
| P0 | 丰富 agent 状态 | 区分 running/waiting/idle/error |
| P0 | 全局状态总览 | 一眼看全局 |
| P0 | 系统通知 | 离开窗口也不漏 |
| P1 | 智能注意力路由 | 减少认知负担 |
| P1 | 动态摘要 | 不聚焦也能判断 |
| P1 | 快捷审批 | 减少操作步骤 |
| P2 | 会话模板 | 减少重复设置 |
| P2 | 分组标签 | 规模化管理 |
| P2 | 活动时间线 | 事后回顾 |
