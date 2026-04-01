# Agent Status & Activity Flow

Moss 通过 Claude Code hooks 追踪每个终端的 agent 状态和活动摘要，在卡片 header 上显示，不聚焦也能判断 agent 在做什么。

## 状态 (AgentStatus)

| 状态 | 含义 | 视觉 |
|------|------|------|
| `running` | agent 正在执行 | 蓝色圆点 |
| `waiting` | 等待用户操作（审批/回答） | 橙色圆点 |
| `idle` | 任务完成/终端空闲 | 绿色圆点 |
| `error` | API 错误 | 红色圆点 |
| `none` | 无 agent 运行 | 灰色圆点 |

### 状态优先级

```
显示状态 = manualStatus > desktopNotificationPending(.waiting) > automaticStatus
```

- `manualStatus`: 通过 `moss agent status set` 手动设置
- `automaticStatus`: 通过 hooks 自动设置（`set_auto_status`）
- `desktopNotificationPending`: 收到桌面通知但未查看时强制显示 `.waiting`

## 活动摘要 (activitySummary)

卡片 header 显示一行文本，描述 agent 当前在做什么：

- 有 tasks 时 → 显示 `TaskProgressIndicator`（进度条 + 当前 task subject）
- 无 tasks 但有 activity 时 → 显示 activity 文本
- 都没有 → 只显示状态圆点

### 清除规则

`activitySummary` 在 `setAutomaticStatus(.running)` 时自动清除。不需要单独清除——任何让 agent 回到 running 的事件都会清掉旧的 activity。

## Hook 事件 → IPC 映射

```
Claude Code Hook          →  IPC Commands                    →  效果
─────────────────────────────────────────────────────────────────────────
SessionStart              →  agent_session_start <id>        →  重置 tasks，清除 activity
                             set_auto_status running            状态=running

UserPromptSubmit          →  set_auto_status running         →  清除旧 activity（running 清除规则）
                             set_activity <prompt>              然后设置新 activity=用户输入

Notification              →  set_auto_status waiting         →  状态=waiting
 (permission/idle/         set_activity <message>              activity=通知内容
  elicitation)                                                  如 "Claude needs your permission to use Bash"

TaskCreated               →  task_created {id, subject}      →  添加 tracked task
                                                                卡片切换到 TaskProgressIndicator

TaskCompleted             →  task_completed {id}             →  标记 task 完成
                                                                全部完成时清空 tasks 列表

Stop                      →  set_auto_status idle            →  状态=idle

StopFailure               →  set_auto_status error           →  状态=error
```

## 典型生命周期

```
用户提交 prompt "fix the auth bug"
  → UserPromptSubmit
  → status=running, activity="fix the auth bug"
  → 卡片: ● fix the auth bug

agent 创建 task
  → TaskCreated
  → 卡片切换: ● ██░░ 1/3 Implement login

agent 遇到权限请求
  → Notification (permission_prompt)
  → status=waiting, activity="Claude needs your permission to use Bash"
  → 卡片: ● Claude needs your permission to use Bash

用户审批，agent 继续
  → (某个 hook 触发 set_auto_status running)
  → activity 自动清除
  → 卡片回到 TaskProgressIndicator 或空

agent 完成
  → Stop
  → status=idle
  → 卡片: ●
```

## CLI 测试

```bash
# 手动设置 activity（在 Moss 终端内）
moss agent activity "debugging auth module"

# 清除 activity
moss agent activity

# 配合状态模拟完整流程
moss agent status auto running    # 会自动清除 activity
moss agent activity "fix the auth bug"
moss agent status auto waiting
moss agent activity "approve file edit?"
moss agent status auto running    # 自动清除 "approve file edit?"
moss agent status auto idle
```
