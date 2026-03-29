defmodule SymphonyElixir.OrchestratorStallDetectionTest do
  @moduledoc """
  Unit tests for the Orchestrator stall-detection logic that was previously
  handled by the external watchdog.sh script.

  Covers:
  - stall_elapsed_ms/2 calculation using last_codex_timestamp and started_at fallback
  - reconcile_stalled_running_issues/1 with timeout disabled (= 0)
  - reconcile_stalled_running_issues/1 with no running agents
  - reconcile_stalled_running_issues/1 with a not-yet-stalled agent
  - reconcile_stalled_running_issues/1 with a stalled agent (triggers retry)
  - reconcile_stalled_running_issues/1 falls back to started_at when last_codex_timestamp is nil
  - reconcile_stalled_running_issues/1 with multiple agents — only stalled ones are restarted
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Workflow

  # Start a local TaskSupervisor so that terminate_task/1 can resolve it
  # without requiring the full Application to be started.
  setup do
    unless Process.whereis(SymphonyElixir.TaskSupervisor) do
      {:ok, _pid} = Task.Supervisor.start_link(name: SymphonyElixir.TaskSupervisor)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_state do
    %State{
      poll_interval_ms: 5_000,
      max_concurrent_agents: 10,
      next_poll_due_at_ms: 0,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      dispatch_cooldowns: %{},
      circuit_breakers: %{},
      terminal_issue_ids: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      codex_rate_limits: nil,
      stats_completed_count: 0,
      stats_failed_count: 0,
      stats_completed_duration_ms: [],
      stats_turn_tokens: [],
      stats_linear_response_time_ms: [],
      stats_issue_started_at_ms: %{},
      stats_finalized_issue_ids: MapSet.new(),
      checkpoint_waiting: %{human_verify: 0, decision: 0, human_action: 0}
    }
  end

  defp make_issue(id) do
    %Issue{
      id: id,
      identifier: "BUB-#{id}",
      title: "Test issue #{id}",
      state: "In Progress",
      url: "https://example.org/issues/BUB-#{id}"
    }
  end

  defp make_running_entry(issue_id, opts \\ []) do
    last_codex_timestamp = Keyword.get(opts, :last_codex_timestamp)
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())
    pid = Keyword.get(opts, :pid, self())

    %{
      pid: pid,
      ref: make_ref(),
      identifier: "BUB-#{issue_id}",
      issue: make_issue(issue_id),
      trace_id: "trace-#{issue_id}",
      session_id: "session-#{issue_id}",
      last_codex_message: nil,
      last_codex_timestamp: last_codex_timestamp,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      context_window_tokens: 400_000,
      context_usage_percent: 0.0,
      turn_count: 0,
      retry_attempt: 0,
      started_at: started_at,
      runtime_name: "claude-sonnet"
    }
  end

  # ---------------------------------------------------------------------------
  # stall_elapsed_ms_for_test/2
  # ---------------------------------------------------------------------------

  describe "stall_elapsed_ms_for_test/2" do
    test "returns elapsed ms from last_codex_timestamp when present" do
      past = DateTime.add(DateTime.utc_now(), -10, :second)
      now = DateTime.utc_now()
      entry = make_running_entry("1", last_codex_timestamp: past)

      elapsed = Orchestrator.stall_elapsed_ms_for_test(entry, now)

      assert is_integer(elapsed)
      assert elapsed >= 9_500
      assert elapsed <= 10_500
    end

    test "falls back to started_at when last_codex_timestamp is nil" do
      past = DateTime.add(DateTime.utc_now(), -30, :second)
      now = DateTime.utc_now()
      entry = make_running_entry("2", started_at: past, last_codex_timestamp: nil)

      elapsed = Orchestrator.stall_elapsed_ms_for_test(entry, now)

      assert is_integer(elapsed)
      assert elapsed >= 29_500
      assert elapsed <= 30_500
    end

    test "returns nil when both last_codex_timestamp and started_at are nil" do
      entry = %{last_codex_timestamp: nil, started_at: nil}
      now = DateTime.utc_now()

      elapsed = Orchestrator.stall_elapsed_ms_for_test(entry, now)

      assert is_nil(elapsed)
    end

    test "returns nil for a non-map running_entry" do
      elapsed = Orchestrator.stall_elapsed_ms_for_test(nil, DateTime.utc_now())
      assert is_nil(elapsed)
    end

    test "returns 0 when activity timestamp is in the future (clock skew guard)" do
      future = DateTime.add(DateTime.utc_now(), 60, :second)
      now = DateTime.utc_now()
      entry = make_running_entry("3", last_codex_timestamp: future)

      elapsed = Orchestrator.stall_elapsed_ms_for_test(entry, now)

      assert elapsed == 0
    end
  end

  # ---------------------------------------------------------------------------
  # reconcile_stalled_running_issues_for_test/1 — disabled path
  # ---------------------------------------------------------------------------

  describe "reconcile_stalled_running_issues_for_test/1 with stall disabled" do
    test "no-ops when stall_timeout_ms is 0" do
      write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 0)

      stale = DateTime.add(DateTime.utc_now(), -3_600, :second)

      worker_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      on_exit(fn -> send(worker_pid, :done) end)

      issue_id = "stall-disabled"
      entry = make_running_entry(issue_id, last_codex_timestamp: stale, pid: worker_pid)

      state =
        base_state()
        |> Map.put(:running, %{issue_id => entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))

      updated = Orchestrator.reconcile_stalled_running_issues_for_test(state)

      # Agent must NOT have been moved to retry
      assert Map.has_key?(updated.running, issue_id)
      assert map_size(updated.retry_attempts) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # reconcile_stalled_running_issues_for_test/1 — empty running map
  # ---------------------------------------------------------------------------

  describe "reconcile_stalled_running_issues_for_test/1 with no running agents" do
    test "returns state unchanged when running map is empty" do
      write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 1_000)

      state = base_state()
      updated = Orchestrator.reconcile_stalled_running_issues_for_test(state)

      assert updated.running == %{}
      assert updated.retry_attempts == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # reconcile_stalled_running_issues_for_test/1 — healthy agent
  # ---------------------------------------------------------------------------

  describe "reconcile_stalled_running_issues_for_test/1 with healthy agent" do
    test "leaves recently active agent untouched" do
      write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 60_000)

      recent = DateTime.add(DateTime.utc_now(), -5, :second)

      worker_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      on_exit(fn -> send(worker_pid, :done) end)

      issue_id = "healthy-agent"
      entry = make_running_entry(issue_id, last_codex_timestamp: recent, pid: worker_pid)

      state =
        base_state()
        |> Map.put(:running, %{issue_id => entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))

      updated = Orchestrator.reconcile_stalled_running_issues_for_test(state)

      assert Map.has_key?(updated.running, issue_id)
      assert map_size(updated.retry_attempts) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # reconcile_stalled_running_issues_for_test/1 — stalled agent
  # ---------------------------------------------------------------------------

  describe "reconcile_stalled_running_issues_for_test/1 with stalled agent" do
    test "moves stalled agent to retry_attempts with transient error class" do
      write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 1_000)

      stale = DateTime.add(DateTime.utc_now(), -10, :second)

      worker_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      on_exit(fn ->
        if Process.alive?(worker_pid), do: send(worker_pid, :done)
      end)

      issue_id = "stalled-agent"
      entry = make_running_entry(issue_id, last_codex_timestamp: stale, pid: worker_pid)

      state =
        base_state()
        |> Map.put(:running, %{issue_id => entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))

      updated = Orchestrator.reconcile_stalled_running_issues_for_test(state)

      refute Map.has_key?(updated.running, issue_id)
      assert Map.has_key?(updated.retry_attempts, issue_id)

      retry = updated.retry_attempts[issue_id]
      assert retry.error_class == "transient"
      assert String.starts_with?(retry.error, "stalled for ")
      assert is_integer(retry.due_at_ms)
    end

    test "uses started_at fallback when last_codex_timestamp is nil" do
      write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 1_000)

      stale_start = DateTime.add(DateTime.utc_now(), -10, :second)

      worker_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      on_exit(fn ->
        if Process.alive?(worker_pid), do: send(worker_pid, :done)
      end)

      issue_id = "stalled-fallback"
      entry = make_running_entry(issue_id, started_at: stale_start, last_codex_timestamp: nil, pid: worker_pid)

      state =
        base_state()
        |> Map.put(:running, %{issue_id => entry})
        |> Map.put(:claimed, MapSet.new([issue_id]))

      updated = Orchestrator.reconcile_stalled_running_issues_for_test(state)

      refute Map.has_key?(updated.running, issue_id)
      assert Map.has_key?(updated.retry_attempts, issue_id)
      assert String.starts_with?(updated.retry_attempts[issue_id].error, "stalled for ")
    end
  end

  # ---------------------------------------------------------------------------
  # reconcile_stalled_running_issues_for_test/1 — mixed agents
  # ---------------------------------------------------------------------------

  describe "reconcile_stalled_running_issues_for_test/1 with mixed stalled/healthy agents" do
    test "only restarts stalled agents, leaves healthy ones running" do
      write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: 5_000)

      stale = DateTime.add(DateTime.utc_now(), -60, :second)
      recent = DateTime.add(DateTime.utc_now(), -1, :second)

      stalled_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      healthy_pid =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      on_exit(fn ->
        if Process.alive?(stalled_pid), do: send(stalled_pid, :done)
        if Process.alive?(healthy_pid), do: send(healthy_pid, :done)
      end)

      stalled_id = "stalled-in-mix"
      healthy_id = "healthy-in-mix"

      stalled_entry = make_running_entry(stalled_id, last_codex_timestamp: stale, pid: stalled_pid)
      healthy_entry = make_running_entry(healthy_id, last_codex_timestamp: recent, pid: healthy_pid)

      state =
        base_state()
        |> Map.put(:running, %{stalled_id => stalled_entry, healthy_id => healthy_entry})
        |> Map.put(:claimed, MapSet.new([stalled_id, healthy_id]))

      updated = Orchestrator.reconcile_stalled_running_issues_for_test(state)

      refute Map.has_key?(updated.running, stalled_id)
      assert Map.has_key?(updated.running, healthy_id)
      assert Map.has_key?(updated.retry_attempts, stalled_id)
      refute Map.has_key?(updated.retry_attempts, healthy_id)
    end
  end
end
