---
tags: [architecture, distributed, production, elixir-cluster]
created: 2026-03-29
modified: 2026-03-29
author: chancellor
status: draft
---

# Symphony 生产级分布式架构

## Context

目标：从单机单进程扩展到分布式部署，支撑多 Linear 项目、海量 issue、高并发 Agent session。
约束：充分利用 Elixir/OTP 原生分布式能力，不引入不必要的外部组件。

## 核心设计：Coordinator + Executor 分离

```
                    Erlang Distribution (libcluster + K8s DNS)
┌───────────────────────────────────────────────────────────────┐
│                                                               │
│  Node 1 (Coordinator)     Node 2 (Executor)   Node N         │
│  ┌─────────────────┐      ┌──────────────┐    ┌──────────┐  │
│  │ Orchestrator     │      │ ExecutorPool │    │ Executor │  │
│  │ (Singleton via   │─────→│ (Horde.      │    │ Pool     │  │
│  │  :global)        │      │  Dynamic     │    │          │  │
│  │                  │      │  Supervisor) │    │          │  │
│  │ • Poll Linear    │      │              │    │          │  │
│  │ • Claim issues   │      │ AgentRunner  │    │ Agent    │  │
│  │ • Dispatch to    │      │ AgentRunner  │    │ Runner   │  │
│  │   Horde pool     │      │ AgentRunner  │    │          │  │
│  │ • Retry/backoff  │      │              │    │          │  │
│  ├─────────────────┤      ├──────────────┤    ├──────────┤  │
│  │ ExecutorPool    │      │ Webhook Recv │    │ Webhook  │  │
│  │ (local份额)     │      │ (Phoenix)    │    │ Recv     │  │
│  └─────────────────┘      └──────────────┘    └──────────┘  │
│           ↕ Phoenix.PubSub (:pg, 跨节点广播) ↕               │
└───────────────────────────────────────────────────────────────┘
```

**Coordinator**（集群单例）：
- 轮询 Tracker、选择 issue、管理 claimed/completed/retry 状态
- 通过 Horde.DynamicSupervisor 将 AgentRunner 分配到集群各节点
- 用 `:global.register_name/2` 实现 leader election，节点故障自动迁移

**Executor**（每个节点）：
- Horde.DynamicSupervisor 的本地份额，接收并执行 AgentRunner 进程
- 管理本地 workspace（git worktree）
- 通过 Phoenix.PubSub 向 Coordinator 汇报进度

**关键洞察**：Coordinator 是轻量的（只做 HTTP 轮询 + 调度决策），不是瓶颈。瓶颈在 Executor（Agent session 吃 CPU/IO）。因此 Coordinator 单例完全足够，Executor 水平扩展。

## 新增依赖

```elixir
# mix.exs — 仅增加 2 个库
{:libcluster, "~> 3.5"},   # K8s 节点发现
{:horde, "~> 0.10"}        # 分布式 Supervisor + Registry
```

Phoenix.PubSub 的 `:pg` backend 是 Erlang 内建，**零额外依赖**即支持跨节点广播。

## 状态分类

| 状态 | 归属 | 分布策略 |
|------|------|----------|
| `claimed` / `completed` / `dispatch_cooldowns` | Coordinator 独占 | 单例 GenServer 内存，故障迁移时重建 |
| `running` (pid/ref/tokens) | Coordinator 维护 | 跨节点 Process.monitor，pid 可跨节点 |
| `retry_attempts` / `circuit_breakers` | Coordinator 独占 | 同上 |
| workspace 状态 | Executor 本地 | 每节点独立管理 |
| Agent session | Executor 本地 | Horde 分配，进程本地执行 |
| 观测性事件 | Phoenix.PubSub 广播 | 所有节点可订阅 |
| WORKFLOW.md 配置 | 每节点 WorkflowStore | 各自轮询本地文件或共享存储 |

## Supervision Tree（集群模式）

```elixir
defmodule SymphonyElixir.Application do
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      # 1. 集群发现
      {Cluster.Supervisor, [topologies, [name: SymphonyElixir.ClusterSupervisor]]},

      # 2. 跨节点消息（:pg backend，Erlang 内建）
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},

      # 3. 分布式 Executor 池（所有节点参与）
      {Horde.DynamicSupervisor,
       name: SymphonyElixir.ExecutorPool,
       strategy: :one_for_one,
       distribution_strategy: Horde.UniformDistribution,
       members: :auto},  # 自动发现集群成员

      # 4. 分布式 Registry（issue claim 去重）
      {Horde.Registry,
       name: SymphonyElixir.IssueRegistry,
       keys: :unique,
       members: :auto},

      # 5. 本地服务
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard,

      # 6. Coordinator 单例（:global 选举，仅一个节点运行）
      SymphonyElixir.CoordinatorStarter
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Coordinator 单例实现

```elixir
defmodule SymphonyElixir.CoordinatorStarter do
  @moduledoc "尝试在当前节点启动 Orchestrator 单例。若已有 leader 则静默退出。"
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def init(_opts) do
    case :global.register_name(:symphony_coordinator, self()) do
      :yes ->
        # 本节点成为 Coordinator
        {:ok, pid} = SymphonyElixir.Orchestrator.start_link(name: :via_global)
        Process.monitor(pid)
        {:ok, %{orchestrator_pid: pid}}

      :no ->
        # 另一节点已是 Coordinator，监控其存活
        case :global.whereis_name(:symphony_coordinator) do
          :undefined -> {:stop, :no_leader}
          pid -> Process.monitor(pid); {:ok, %{orchestrator_pid: pid}}
        end
    end
  end

  # Leader 崩溃 → 尝试接管
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, _state) do
    {:stop, :leader_down, %{}}  # restart → 重新竞选
  end
end
```

**故障迁移**：Coordinator 节点宕机 → `:global` 释放名称 → 其他节点的 CoordinatorStarter restart → 重新竞选 → 新 leader 从 Tracker 重建 claimed 状态（poll 一次即可恢复）。

## 分布式任务派发

当前 `do_dispatch_issue_with_runtime` 用 `Task.Supervisor.start_child` 本地派发。改为 Horde：

```elixir
defp do_dispatch_issue_with_runtime(state, issue, attempt, runtime) do
  # Horde 自动选择负载最低的节点
  child_spec = %{
    id: {:agent_runner, issue.id},
    start: {SymphonyElixir.AgentRunner.Worker, :start_link,
            [%{issue: issue, runtime: runtime, attempt: attempt,
               recipient: self(),  # Coordinator pid，可跨节点接收消息
               trace_id: new_trace_id()}]},
    restart: :temporary
  }

  case Horde.DynamicSupervisor.start_child(SymphonyElixir.ExecutorPool, child_spec) do
    {:ok, pid} ->
      ref = Process.monitor(pid)  # 跨节点 monitor 在 Erlang 中原生支持
      # ... 写入 state.running，与现在逻辑相同
  end
end
```

**关键**：Erlang 的 `Process.monitor/1` 和消息发送 `send(pid, msg)` **天然支持跨节点**。Coordinator 在 Node1，AgentRunner 在 Node3，`{:DOWN, ref, ...}` 消息仍能正常送达。无需 RPC 封装。

## Webhook + Polling 混合

在现有 Phoenix endpoint 上增加 Linear webhook receiver，**不引入 n8n**：

```elixir
# router.ex
scope "/api/v1" do
  post "/webhook/linear", WebhookController, :linear
end
```

```elixir
defmodule SymphonyElixirWeb.WebhookController do
  def linear(conn, %{"action" => "create", "data" => issue_data}) do
    # 通知 Coordinator 立即检查（而非等下一个 poll cycle）
    case :global.whereis_name(:symphony_coordinator) do
      :undefined -> :noop
      pid -> send(pid, {:webhook_issue_event, issue_data})
    end
    json(conn, %{ok: true})
  end
end
```

Coordinator 收到 webhook → 立即触发一次 dispatch（延迟从 polling interval 降到 <1s）。Polling 保留作为 fallback（Linear webhook 有已知丢失问题）。

## 多 Linear 项目支持

当前 WORKFLOW.md 绑定单个 `tracker.project_slug`。扩展为多项目：

```yaml
# WORKFLOW.md
tracker:
  kind: linear
  projects:
    - slug: "project-a"
      team_key: "TEAM-A"
    - slug: "project-b"
      team_key: "TEAM-B"
```

Coordinator 轮询时合并所有项目的 candidate issues，其余流程不变。

或者：**多个 WORKFLOW.md**——每个项目一份配置，Coordinator 加载多份 workflow。

## K8s 部署模型

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: symphony
spec:
  replicas: 5  # 1 自动成为 Coordinator，4 为 Executor
  template:
    spec:
      containers:
      - name: symphony
        image: symphony:latest
        env:
        - name: RELEASE_NODE
          valueFrom:
            fieldRef:
              fieldPath: status.podIP  # 每 Pod 唯一节点名
        - name: RELEASE_DISTRIBUTION
          value: "name"
        ports:
        - containerPort: 4000  # Phoenix
        - containerPort: 4369  # EPMD
        - containerPort: 9100  # Erlang distribution
        volumeMounts:
        - name: workspaces
          mountPath: /workspaces
      volumes:
      - name: workspaces
        emptyDir:
          sizeLimit: 20Gi
---
apiVersion: v1
kind: Service
metadata:
  name: symphony-headless
spec:
  clusterIP: None  # Headless → libcluster DNS 发现
  selector:
    app: symphony
  ports:
  - port: 4369
    name: epmd
```

**扩缩容**：
- HPA 按 Coordinator 暴露的 `running_count / max_concurrent` metric 扩缩
- 新 Pod 加入 → libcluster 发现 → Horde 自动纳入 ExecutorPool → 分担新任务
- Pod 缩容 → Horde 检测离开 → 运行中的 session 丢失（需重建，见下文容错设计）

## 容错设计

### Executor 节点宕机

1. Horde 检测成员离开
2. 该节点上的 AgentRunner 进程死亡
3. Coordinator 收到 `{:DOWN, ref, ...}`（Erlang 跨节点 monitor）
4. 触发现有 retry 逻辑（continuation 或 failure retry）
5. 新 retry 派发到存活节点

**已有代码完全覆盖此场景**——`handle_info({:DOWN, ...})` 已处理进程异常退出。

### Coordinator 节点宕机

1. `:global` 释放名称
2. 其他节点 CoordinatorStarter restart → 竞选新 leader
3. 新 Coordinator 初始化 → 首次 poll 从 Tracker 重建 `running` 状态
4. 恢复时间：<10s（Supervisor restart + poll cycle）

**丢失的状态**：
- `claimed` / `completed` MapSet → 从 Tracker 当前状态重建
- `retry_attempts` → 丢失，但 poll 会重新发现仍 active 的 issue 并 dispatch
- `stats_*` → 丢失（可接受，或持久化到 ETS/Mnesia）

### 网络分区

Erlang distribution 断裂 → 可能出现两个 Coordinator（split brain）。

**缓解**：
- Horde 使用 CRDT，最终一致——分区恢复后自动合并
- `:global` 在分区恢复后执行 conflict resolution（杀掉一个 Coordinator）
- 最坏情况：同一 issue 被两个节点 dispatch → Agent 跑两遍 → PR 可能重复 → **可接受**（Linear 状态变更是幂等的）

## 并发估算

| 配置 | 说明 |
|------|------|
| 单节点 5 并发 | 当前默认（Agent 是 I/O 密集，可提高） |
| 5 节点 × 5 并发 | 25 并发 session |
| 10 节点 × 10 并发 | 100 并发 session |
| 每 session 平均 15 min | 100 并发 → 400 issues/hr |

**瓶颈分析**：
- Coordinator 轮询：单次 Linear GraphQL 查询 <1s，不是瓶颈
- LLM API rate limit：真正瓶颈，与架构无关，需多 API key 轮转
- Git clone + npm ci：每 session 30-120s 冷启动，可用 warm pool 缓解

## 渐进式迁移路径

```
Phase 0: Config 解耦（前置条件）
  └─ Config.settings!() → 参数注入
  └─ 改动：AgentRunner/Workspace/Backend 约 20 处
  └─ 验证：单元测试传 mock config，不依赖 WORKFLOW.md
  └─ 风险：零（纯内部重构）

Phase 1: Coordinator/Executor 分离（单机验证）
  └─ 拆分 Orchestrator 为 Coordinator + ExecutorPool
  └─ 仍在单节点运行，但架构上已分离
  └─ 验证：功能回归测试全通过

Phase 2: 集群化（2-3 节点）
  └─ 引入 libcluster + Horde
  └─ 本地 docker-compose 起 3 节点验证
  └─ Phoenix.PubSub 配置 :pg adapter
  └─ 验证：杀掉 Coordinator 节点 → 新 leader 接管 → session 继续

Phase 3: K8s 部署
  └─ mix release 打包（含 ERTS）
  └─ Helm chart / K8s manifests
  └─ HPA 配置
  └─ 验证：kubectl scale → Horde 自动分配 → 新节点接收任务

Phase 4: 生产加固（按需）
  └─ Coordinator 状态持久化（Mnesia 或 Redis）
  └─ Workspace warm pool
  └─ 多 Linear 项目支持
  └─ LLM API key 轮转 + 成本追踪
  └─ 安全隔离（gVisor / seccomp）
```

**Phase 0-1 可立即开始**，不影响现有单机运行。Phase 2 引入的新依赖仅 libcluster + horde（两个成熟库）。

## 与 turnkey-ux 路线图的关系

两条线并行，共享 Phase 0（Config 解耦）：

```
turnkey-ux:    CLI重构 → 观测性 → Init → 二进制分发
                  ↑ 共享
production:    Config解耦 → Coordinator/Executor分离 → 集群化 → K8s
```

单用户/小团队：用 `symphony on`（内置 Coordinator，单进程）
平台级：K8s 部署多节点集群（Coordinator 单例 + Executor 池）

**同一份代码，两种运行模式**：
- 单机模式：CoordinatorStarter 检测无集群 → Orchestrator + 本地 Task.Supervisor（现有逻辑）
- 集群模式：libcluster 连接节点 → Horde 接管 → 分布式执行

## 对比：此方案 vs 前版 n8n+Queue 方案

| 维度 | n8n+Queue+K8s | Elixir 原生集群 |
|------|--------------|----------------|
| 新增外部组件 | 5-6 个 | **0 个**（libcluster/horde 是 Elixir 库） |
| 运维复杂度 | 高（n8n HA + NATS + ClickHouse） | **低**（一个 Deployment + headless Service） |
| 代码改动 | 大（新编排层 + worker 协议） | **中**（拆分 Orchestrator + 注入 Config） |
| 延迟 | Queue 入队/出队增加 ~100ms | **零额外延迟**（Erlang 进程间消息 <1ms） |
| 扩展上限 | 理论无限 | ~50-100 节点（Erlang distribution 限制） |
| 超大规模 fallback | 已在架构中 | 引入 Redis Streams 做 task queue |

**50 节点以内，Elixir 原生方案在各维度碾压外部组件方案。**

## 验证方式

- Phase 0: `mix test` 全通过，Config 不依赖 WORKFLOW.md
- Phase 1: 单机运行，功能回归
- Phase 2: `docker-compose up --scale symphony=3`，验证：
  - 仅一个节点成为 Coordinator（查日志）
  - Agent session 分布在不同节点执行
  - 杀 Coordinator 容器 → 10s 内新 leader 接管
  - 杀 Executor 容器 → 其上 session 自动 retry 到其他节点
- Phase 3: K8s 上 `kubectl scale deployment symphony --replicas=10` → 并发处理 issue
- Phase 4: 持续运行 24h 无状态泄漏
