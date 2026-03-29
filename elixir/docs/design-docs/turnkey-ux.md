---
tags: [architecture, cli, observability, distribution]
created: 2026-03-29
modified: 2026-03-29
author: chancellor
status: draft
---

# Symphony "开箱即用" 设计文档

## Context

目标：用户下载 `symphony` 二进制，在项目目录执行 `symphony on`，即刻运转，且能清晰看到每个 agent 在做什么。
当前两大痛点：(1) 启动繁琐 (2) 观测性极差——只保留 last event，不知 subagent 在干嘛。

## 差距总览

| 维度 | 现状 | 目标 | 差距 |
|------|------|------|------|
| **分发** | escript，需 Erlang 28 + Elixir 1.19 | 单一二进制 | **大** |
| **CLI** | 单一模式 + 60 字符 guardrail flag | `symphony on/off/status/init/doctor` | **中** |
| **配置** | 手写 ~60 行 WORKFLOW.md | `symphony init` 交互式 | **中** |
| **观测性** | 仅存 last event/issue，无活动日志，无流式输出 | 完整活动轨迹 + 实时流 + 日志查询 | **大** |
| **凭证** | 手动 export API Key | 自动解析链 | **小** |
| **进程管理** | 前台，无 off/status | HTTP 停机 + 状态查询 | **小** |

---

## 实施路线（5 个阶段）

### Phase 1: CLI 子命令 + 免 Flag

**目标**：`symphony on` 即可启动，无需 flag，无需向后兼容旧调用方式。

**改动文件**：
- `lib/symphony_elixir/cli.ex` — 重构为子命令路由，**删除旧 OptionParser 逻辑**

**子命令**：
```
symphony on [--port N] [--logs-root PATH] [--workflow PATH]
symphony off
symphony status
symphony init [--demo]
symphony doctor
symphony dynamic-tools-mcp [...]
```

**Guardrail**：
- 首次 `symphony on`：打印 banner → 提示 YES → 写 `~/.config/symphony/.consented` 标记文件
- 后续：检测标记文件存在即通过
- `--i-understand-...` flag 保留供 CI 使用，但不保留旧的位置参数调用方式

---

### Phase 2: 观测性 + Between-Turn 干预

**目标**：(1) 完整活动轨迹——看清每个 agent 在做什么 (2) between-turn 纠偏——在轮次间注入用户指令

#### 技术约束

三种后端（Codex/Claude/OpenCode）**均不支持 mid-turn 注入**（request-response 协议，无 stdin 通道）。但 **between-turn 注入完全可行**：AgentRunner 的 turn loop 在每轮结束后有间隙，此处可检查用户干预队列。

| 后端 | Between-turn 机制 |
|------|-------------------|
| Codex | 新 `turn/start` RPC 可携带追加 prompt |
| Claude | `--resume <session_id>` + 新 prompt |
| OpenCode | 新 `session/prompt()` RPC |

#### 当前缺陷

| 能力 | 现状 | 问题 |
|------|------|------|
| 事件历史 | 仅存 `last_codex_event` | 所有中间轮次丢弃 |
| 工具调用 | 仅显示工具名 | 无参数/结果 |
| Agent 输出 | 不可见 | 无 streaming，无 thought process |
| Token 分布 | 累计总量 | 无 per-turn 明细 |
| 用户干预 | 不可能 | 只能通过 Linear 状态变更间接影响 |
| 已完成 issue | 仅 ID 存入 `completed` MapSet | 详情全部丢弃 |
| 任务耗时/token 统计 | 累计 token 在内存中，完成后丢弃 | 无持久化，无 per-issue 汇总报告 |

#### 2A: Issue 完成报告（Completion Report）

每个 issue 完成（进入 terminal state）时，生成并持久化一份完成报告：

```elixir
%{
  issue_id: String.t(),
  issue_identifier: String.t(),       # e.g. "BUB-123"
  runtime_name: String.t(),           # e.g. "default-codex", "claude-reviewer"
  result: :completed | :failed | :cancelled,
  started_at: DateTime.t(),
  finished_at: DateTime.t(),
  duration_ms: non_neg_integer(),     # wall-clock 耗时
  turns: non_neg_integer(),           # 总轮次数
  tokens: %{
    input: non_neg_integer(),
    output: non_neg_integer(),
    total: non_neg_integer()
  },
  tokens_per_turn: [%{turn: integer(), input: integer(), output: integer()}],
  error: String.t() | nil             # 失败时的错误信息
}
```

**存储**：
- 内存：`completed` MapSet **保持不变**（去重语义），新增独立字段 `completion_reports`（`:queue` 环形缓冲，最近 100 条）
- 磁盘：追加写入 `{workspace_root}/.symphony/completion_log.jsonl`（每行一条 JSON），持久化全量历史

**展示**：
- Terminal Dashboard：issue 完成时打印单行摘要 `✓ BUB-123 done in 12m34s, 3 turns, 45.2k tokens`
- Web Dashboard：已完成 issue 列表含耗时/token 列，可排序
- API：`GET /api/v1/issues/completed` 返回报告列表
- CLI：`symphony logs --issue BUB-123 --full` 末尾附带完成报告

**改动文件**：
- `lib/symphony_elixir/orchestrator.ex` — 完成时生成报告，存入 state
- 新建 `lib/symphony_elixir/completion_report.ex` — 报告结构体 + JSONL 持久化
- `lib/symphony_elixir/status_dashboard.ex` — 完成时打印摘要行
- `lib/symphony_elixir_web/live/dashboard_live.ex` — 已完成列表增加耗时/token 列

#### 2B: Issue 活动日志（Activity Log）


**核心改动**：Orchestrator 从 "只记 last event" 变为 "追加到 activity log"。

**改动文件**：
- `lib/symphony_elixir/orchestrator.ex` — `integrate_codex_update/2` 中追加事件
- 新建 `lib/symphony_elixir/activity_log.ex` — 基于 ETS 的 per-issue 环形缓冲（非 GenServer state，避免内存压力）

**数据结构**（每条 entry）：
```elixir
%{
  timestamp: DateTime.t(),
  event: atom(),           # :turn_started, :tool_call, :message_delta, :turn_completed, etc.
  turn: integer(),
  detail: map(),           # 工具名+参数摘要 / agent 输出文本 / 错误信息（截断大负载）
  tokens: %{input: int, output: int}  # per-event token 快照
}
```

- 运行中 issue：保留最近 500 条/issue
- 已完成 issue：保留最近 20 个的活动日志，FIFO 淘汰
- **全局内存上限**：所有 issue 合计不超过 200MB，超出时 LRU 淘汰最旧已完成 issue
- `detail` 字段中工具参数/agent 输出截断至 2KB，避免大负载撑爆内存

#### 2C: Between-Turn 用户干预机制

**核心思路**：用户通过 API/Dashboard/CLI 向 issue 排入纠偏指令，AgentRunner 在 turn 间隙消费并注入下一轮 prompt。

**新建文件**：
- `lib/symphony_elixir/intervention.ex` — 干预队列（GenServer，per-issue ETS 或 Agent）

**改动文件**：
- `lib/symphony_elixir/agent_runner.ex` — `do_run_codex_turns/N` turn loop 中，在 `run_turn()` 之前检查干预队列：
  ```elixir
  # 伪代码：turn loop 中插入
  user_directive = Intervention.pop(issue_id)
  prompt = if user_directive do
    original_prompt <> "\n\n---\nOperator directive: " <> user_directive
  else
    original_prompt
  end
  {:ok, turn_result} = backend.run_turn(session, prompt, issue, opts)
  ```
- `lib/symphony_elixir/prompt_builder.ex` — 支持追加 operator directive 段

**API 端点**：
- `POST /api/v1/issues/:id/intervene` body: `{"directive": "停下来，不要修改 auth 模块，改用 middleware 方案"}`

**CLI 命令**：
```
symphony intervene BUB-123 "停下来，改用 middleware 方案"
```

**Web Dashboard**：issue 行增加 "干预" 按钮 → 弹出输入框 → 提交 directive

**时序**：
```
Turn N 执行中 → Turn N 结束 → AgentRunner 检查 Intervention 队列
  → 有指令 → prepend 到 Turn N+1 prompt → 执行 Turn N+1
  → 无指令 → 正常执行 Turn N+1
```

**限制说明**：
- 此为 between-turn 机制，非实时 TTY。用户指令在当前 turn 结束后才生效（turn 通常几十秒到几分钟）。
- **Best-effort**：干预指令追加到 prompt，依赖 LLM 语义理解。不同后端/上下文敏感度不同，不保证 agent 100% 遵从。建议将 directive 置于 prompt 高优先级位置（system-level），并记录是否生效供用户判断。

#### 2D: 实时 Agent 输出流

**双通道设计**：
- **Web Dashboard（LiveView）**：直接用 Phoenix.PubSub subscribe（复用已有 WebSocket 连接，零额外连接开销）
- **CLI / 外部客户端**：新建 Phoenix Channel `/ws/agent/:issue_id`

**新建文件**：
- `lib/symphony_elixir_web/channels/agent_channel.ex` — Phoenix Channel（供 CLI 和非 LiveView 客户端）

**机制**：
- `on_message` 回调每条事件广播到 PubSub topic `"agent:#{issue_id}"`
- LiveView 详情页直接 `Phoenix.PubSub.subscribe(topic)` 接收实时事件
- CLI `symphony logs --follow <issue_id>` 通过 Channel WebSocket 消费

**包含内容**：
- 轮次开始/结束
- 工具调用（名称 + 参数摘要 + 结果摘要，截断长内容）
- Agent 文本输出（Claude: `agent_message` 含全文；Codex/OpenCode: 结构化事件）
- Token 消耗（per-turn）
- 错误及上下文
- 用户干预指令的注入记录

#### 2E: 观测性 API 增强

**改动文件**：
- `lib/symphony_elixir_web/controllers/observability_api_controller.ex`
- `lib/symphony_elixir_web/router.ex`

**新增端点**：
- `GET /api/v1/issues/:id/activity` — 完整活动日志
- `GET /api/v1/issues/:id/activity?since=<ts>` — 增量拉取
- `GET /api/v1/issues/completed` — 最近已完成 issue 列表及摘要
- `GET /api/v1/issues/:id/tokens` — per-turn token 明细
- `POST /api/v1/issues/:id/intervene` — 排入纠偏指令（见 2B）

#### 2F: Web Dashboard 重建

当前 Dashboard（`dashboard_live.ex`）仅展示汇总 metric + running sessions 表格（仅 last event），无法深入单个 issue。需重建为两级结构：总览页 + Issue 详情页。

**总览页** (`/dashboard`)：

现有 metric grid + stats 保留。Running sessions 表格增加 **Workflow 阶段进度条**：

```
┌─────────┬──────────────────────────────────────┬────────┬──────────┬──────┐
│ Issue   │ Workflow Stage                        │ Turns  │ Duration │ Tkns │
├─────────┼──────────────────────────────────────┼────────┼──────────┼──────┤
│ BUB-123 │ ●Todo → ●InProg → ○Review → ○Merge  │ 5/16   │ 4m12s    │ 23k  │
│ BUB-456 │ ●Todo → ●InProg → ●Review → ○Merge  │ 12/16  │ 18m03s   │ 67k  │
│ BUB-789 │ ●Todo → ●InProg → ○Review → ○Merge  │ 2/16   │ 1m30s    │ 8k   │
└─────────┴──────────────────────────────────────┴────────┴──────────┴──────┘
```

Running 表格每行必须包含：**耗时**（wall-clock，从 `started_at` 实时计算）和 **token 消耗**（input/output/total）。hover 显示 in/out 明细。

每行的 Workflow Stage 进度条：
- **阶段序列数据源**：WORKFLOW.md 新增可选字段 `tracker.workflow_stages`（有序列表），显式定义阶段顺序。缺省时 fallback 为 `active_states ++ terminal_states` 拼接（注意：`active_states` 是无序集合，fallback 仅为近似）
  ```yaml
  tracker:
    workflow_stages:  # 可选，显式定义有序阶段
      - Todo
      - In Progress
      - Auto Review
      - Human Review
      - Merging
      - Done
  ```
- 当前阶段高亮（实心圆 ●），已过阶段灰色实心，未达阶段空心 ○
- 颜色编码：Todo=蓝、In Progress=绿、Review=橙、Human Review=红、Merging=紫、Done=灰
- 点击 issue 行 → 导航到 Issue 详情页

已完成 issue 列表：末尾增加 "Completed" 区块，展示最近 20 条：

```
┌─────────┬──────────────────────────────────────┬────────┬──────────┬──────┬────────┐
│ Issue   │ Workflow Stage (final)                │ Turns  │ Duration │ Tkns │ Result │
├─────────┼──────────────────────────────────────┼────────┼──────────┼──────┼────────┤
│ BUB-100 │ ●Todo → ●InProg → ●Review → ●Done   │ 8      │ 12m34s   │ 45k  │ ✓      │
│ BUB-099 │ ●Todo → ●InProg → ✗ Failed           │ 3      │ 5m12s    │ 18k  │ ✗      │
└─────────┴──────────────────────────────────────┴────────┴──────────┴──────┴────────┘
```

每行含：最终 workflow 阶段、总轮次、总耗时、总 token、结果（✓/✗）。可按任意列排序。

**Issue 详情页** (`/dashboard/issues/:identifier`)：

新建 LiveView 页面，每个 issue 的完整观测视图：

```
┌─────────────────────────────────────────────────────────────┐
│  BUB-123: Fix auth middleware                               │
│  Runtime: default-codex │ Session: a1b2c3d4 │ Turn 5/16    │
├─────────────────────────────────────────────────────────────┤
│  Workflow Progress                                          │
│  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━░░░░░░░░░░░░░ 60%  │
│  ● Todo → ● In Progress → ○ Auto Review → ○ Merging → ○ Done│
├─────────────────────────────────────────────────────────────┤
│  Activity Timeline                           │ Token Usage  │
│  ┌──────────────────────────────────────┐   │ ┌──────────┐ │
│  │ 14:02:33 turn_started (turn 5)      │   │ │ Turn 1 ▓ │ │
│  │ 14:02:45 tool_call: Edit auth.ts    │   │ │ Turn 2 ▓▓│ │
│  │ 14:03:12 tool_call: Bash npm test   │   │ │ Turn 3 ▓ │ │
│  │ 14:03:58 message: "Tests passing"   │   │ │ Turn 4 ▓▓│ │
│  │ 14:04:01 turn_completed             │   │ │ Turn 5 ░ │ │
│  │          tokens: in=3.2k out=1.1k   │   │ └──────────┘ │
│  └──────────────────────────────────────┘   │              │
├─────────────────────────────────────────────────────────────┤
│  Intervene: [________________________________] [Send]       │
├─────────────────────────────────────────────────────────────┤
│  Completion Report (if finished)                            │
│  Duration: 12m34s │ Turns: 5 │ Tokens: 23,456 │ Result: ✓  │
└─────────────────────────────────────────────────────────────┘
```

**页面组成**：

1. **Header**：Issue identifier + title + runtime + session ID + turn 进度
2. **Workflow 进度条**：与总览页相同的阶段序列，但更大更详细，显示每阶段进入/离开时间
3. **Activity Timeline**（左栏）：从 ActivityLog 实时拉取，通过 Agent Channel 推送新事件，自动滚动到底部
4. **Token Usage**（右栏）：per-turn 柱状图（input/output 双色），context window 使用百分比仪表
5. **Intervene 输入框**：提交 directive → `POST /api/v1/issues/:id/intervene`
6. **Completion Report**：issue 完成后显示汇总（duration、turns、tokens、result）

**改动文件**：
- `lib/symphony_elixir_web/live/dashboard_live.ex` — 重构总览页，增加 workflow 进度条
- 新建 `lib/symphony_elixir_web/live/issue_detail_live.ex` — Issue 详情页
- `lib/symphony_elixir_web/router.ex` — 增加 `live "/dashboard/issues/:identifier", IssueDetailLive`
- `lib/symphony_elixir_web/presenter.ex` — 增加 workflow stage 计算逻辑
- `priv/static/dashboard.css` — 进度条、时间线、柱状图样式

**Workflow 阶段数据来源**：
- `Config.settings!().tracker.workflow_stages`（优先）或 `active_states ++ terminal_states` → 构建阶段列表
- `running_entry.issue.state` → 当前阶段
- LiveView 实时更新：PubSub 收到 `:observability_updated` → 刷新进度条

**Terminal Dashboard** (`status_dashboard.ex`)：
- 按 issue 展示最近 5 条事件（非仅 last event）
- 当前 turn 工具调用序列
- Context 使用 >70% 黄色，>90% 红色
- 每行增加简化版 workflow stage 指示：`[Todo → InProg → ···]`

#### 2G: `symphony logs` + `symphony intervene` CLI

```
symphony logs                              # 尾随所有 agent 活动
symphony logs --issue BUB-123              # 尾随特定 issue
symphony logs --issue BUB-123 --full       # 查看完整活动历史
symphony intervene BUB-123 "换个方案..."    # 排入纠偏指令
```

---

### Phase 3: 凭证管理 + 零配置 + Init + Doctor

#### 3A: 凭证管理

**新建文件**：`lib/symphony_elixir/credentials.ex`

解析链：env var → `~/.config/symphony/credentials.json` → macOS Keychain → `.env`

集成点：`config/schema.ex` 的 `finalize_settings/1`

#### 3B: 零配置默认值

**改动文件**：`config/schema.ex`、`workspace.ex`

- `hooks.after_create` 为 nil → 从 `.git/config` 推导 clone URL + lockfile 检测安装命令
- `hooks.before_run` 默认 `git fetch origin main && git merge origin/main --no-edit || true`

最小 WORKFLOW.md：
```yaml
---
tracker:
  kind: linear
  project_slug: "b2f9becf3a3c"
---
```

#### 3C: 交互式 Init + Demo Mode

**新建文件**：`lib/symphony_elixir/init.ex`

**OTP 启动策略**：init 阶段仅 `Application.ensure_all_started(:req)`，不启动 Symphony 本体。

标准流程：检测 git → 选 tracker → 输入 API Key → 发现 project → 创建 Linear 状态 → 检测后端 → 检测构建系统 → 生成 WORKFLOW.md → 验证

Demo Mode（`symphony init --demo`）：`tracker.kind: memory`，注入样例 issue，零外部依赖即可体验。

#### 3D: `symphony doctor`

**新建文件**：`lib/symphony_elixir/doctor.ex`

逐项检查：WORKFLOW.md 合法性、API Key 有效性、Agent 后端可执行、Git remote 可达、Workspace root 可写。输出 ✓/✗ + 修复建议。

---

### Phase 4: 二进制分发

**方案**：`mix release`（含 ERTS）+ 平台 tarball + install 脚本

**步骤**：
1. `mix.exs` 增加 release 配置
2. CLI 入口适配 release custom command
3. 新建 `rel/`（`vm.args.eex`、`env.sh.eex`）
4. GitHub Actions CI 矩阵构建：`macos-arm64`、`macos-x86_64`、`linux-x86_64`、`linux-arm64`
5. 上传 GitHub Releases + `install.sh`
6. （可选）Homebrew tap

**用户体验**：
```bash
curl -fsSL https://raw.githubusercontent.com/odysseus0/symphony/main/install.sh | sh
```

---

### Phase 5: 进程管理

#### 5A: 优雅停机
- `POST /api/v1/shutdown` 触发优雅停机序列（非直接 `:init.stop/0`）
- 停机序列：(1) 通知 Dashboard 客户端 "shutting down" (2) 等待当前 turn 完成（最长 `turn_timeout_ms`，可配置上限 60s）(3) 清理 workspace hooks (4) `:init.stop/0`
- `symphony off` 优先 HTTP，fallback SIGTERM
- `symphony on` 写 `~/.config/symphony/instance.json`（port、pid、启动时间、项目路径）
- **注意**：用户可能正在 Dashboard 观察 + intervene，`symphony off` 不应立即杀进程

#### 5B: 内化 Watchdog
将 `watchdog.sh` rate-limit 检测逻辑迁入 Orchestrator 健康检查

---

## 前置条件：Config 解耦

观测性（Phase 2）和未来分布式架构共享同一前置条件：将 `Config.settings!()` 全局调用改为参数注入。

当前 `Config.settings!()` 在 **12 个文件、47 处**被调用（orchestrator 11 处、workspace 9 处、plane/client 6 处为密度最高）。此重构为纯内部改动，不影响功能，但工作量不小。

**可分批推进**：Phase 2 仅需解耦 AgentRunner/ActivityLog 相关的调用（~10 处），无需一次性改完全部 47 处。其余在后续 Phase 按需解耦。

详见 [production-scale.md](./production-scale.md) Phase 0。

## 时序与依赖

```
Phase 1 (CLI) ─┐
               ├──→ Phase 2 (观测性，最高 ROI) ──→ Phase 3 (凭证+Init+Doctor)
Config 解耦 ───┘                                          │
                              Phase 4 (二进制分发) ←─ 可并行 ┘
                                     │
                                     v
                              Phase 5 (进程管理)
```

Phase 1 和 Config 解耦可并行。Phase 2 是最高 ROI——不依赖 CLI 重构即可独立交付（现有 `--i-understand-...` 启动方式仍可用）。

**MVP**（Phase 2）— 现有用户立即获得：完整观测性 + Web Dashboard + 干预机制
**易用**（Phase 1+2）— 加上 `symphony on` 免 flag
**开箱即用**（Phase 1-3）— 有 Erlang 的用户：`symphony init` + `symphony on`
**完整愿景**（Phase 1-4）— 下载即用

## 验证方式

- Phase 1: `symphony on` 无 flag 正常启动；旧调用方式报 usage 错误
- Phase 2:
  - `symphony logs --issue BUB-123` 实时显示 agent turn/tool_call/输出
  - Web Dashboard 点击 issue 展开完整活动时间线（非仅 last event）
  - `symphony intervene BUB-123 "改方案"` → 下一轮 prompt 包含该指令 → agent 行为改变
  - `GET /api/v1/issues/:id/activity` 返回完整事件列表含 per-turn token
  - 已完成 issue 仍可查看历史活动
- Phase 3: 空项目 `symphony init` 生成合法 WORKFLOW.md；`symphony doctor` 逐项报告；`symphony init --demo` + `symphony on` 零配置运转
- Phase 4: 无 Erlang 的干净 macOS 下载二进制正常运行
- Phase 5: `symphony on` → `symphony status` → `symphony off` 全流程
