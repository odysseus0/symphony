defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, ErrorClassifier, RateLimitCircuitBreaker, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Linear.Issue

  @continuation_base_delay_ms 5_000
  @continuation_max_delay_ms 300_000
  @max_continuation_retries 2
  @failure_retry_base_ms 10_000
  @human_review_state "Human Review"
  @stats_max_samples 5_000
  @stats_max_turn_samples 500
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }
  @empty_checkpoint_waiting %{
    human_verify: 0,
    decision: 0,
    human_action: 0
  }

  # Per-issue dispatch cooldown: exponential backoff 30s → 60s → 120s → … → 300s cap
  @dispatch_cooldown_base_ms 30_000
  @dispatch_cooldown_max_ms 300_000

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :workspace_usage_bytes,
      :workspace_usage_refresh_ref,
      :workspace_threshold_exceeded?,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil,
      stats_completed_count: 0,
      stats_failed_count: 0,
      stats_completed_duration_ms: [],
      stats_turn_tokens: [],
      stats_linear_response_time_ms: [],
      stats_issue_started_at_ms: %{},
      stats_finalized_issue_ids: MapSet.new(),
      dispatch_wave: nil,
      checkpoint_waiting: %{},
      dispatch_cooldowns: %{},
      circuit_breakers: %{},
      terminal_issue_ids: MapSet.new()
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      stats_completed_count: 0,
      stats_failed_count: 0,
      stats_completed_duration_ms: [],
      stats_turn_tokens: [],
      stats_linear_response_time_ms: [],
      stats_issue_started_at_ms: %{},
      stats_finalized_issue_ids: MapSet.new(),
      checkpoint_waiting: @empty_checkpoint_waiting
    }

    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = run_workspace_housekeeping(state, :poll)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        state = check_rate_limit_circuit_breaker(state, running_entry, reason)
        session_id = running_entry_session_id(running_entry)

        state =
          with_running_entry_logger_metadata(running_entry, fn ->
            state =
              case reason do
                :normal ->
                  if MapSet.member?(state.terminal_issue_ids, issue_id) do
                    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; issue already marked terminal, releasing claim")

                    identifier = running_entry.identifier
                    cleanup_issue_workspace(identifier)

                    state
                    |> complete_issue(issue_id)
                    |> record_issue_outcome(issue_id, "done")
                    |> release_issue_claim(issue_id)
                  else
                    continuation_attempt =
                      case running_entry[:retry_attempt] do
                        a when is_integer(a) and a > 0 -> a + 1
                        _ -> 1
                      end

                    Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling continuation check (attempt #{continuation_attempt})")

                    state
                    |> complete_issue(issue_id)
                    |> schedule_issue_retry(issue_id, continuation_attempt, %{
                      identifier: running_entry.identifier,
                      trace_id: running_entry[:trace_id],
                      delay_type: :continuation
                    })
                  end

                _ ->
                  failure_attempt =
                    case next_retry_attempt_from_running(running_entry) do
                      attempt when is_integer(attempt) and attempt > 0 -> attempt
                      _ -> 1
                    end

                  issue = Map.get(running_entry, :issue)
                  error_class = ErrorClassifier.classify(reason)
                  error_class_label = ErrorClassifier.to_string(error_class)

                  Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)} error_class=#{error_class_label} next_retry_attempt=#{failure_attempt}")

                  handle_worker_failure(
                    state,
                    issue,
                    issue_id,
                    running_entry.identifier || issue_id,
                    reason,
                    error_class,
                    failure_attempt
                  )
              end

            Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} reason=#{inspect(reason)}")
            state
          end)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)

        state =
          state
          |> apply_codex_token_delta(token_delta)
          |> apply_codex_rate_limits(update)
          |> record_turn_token_usage(issue_id, updated_running_entry, update)

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:agent_issue_terminal, issue_id, state_name}, state)
      when is_binary(issue_id) and is_binary(state_name) do
    Logger.info("Agent reported terminal state for issue_id=#{issue_id} state=#{state_name}; caching")
    {:noreply, mark_issue_terminal(state, issue_id)}
  end

  def handle_info({:agent_issue_terminal, _issue_id, _state_name}, state),
    do: {:noreply, state}

  def handle_info({:linear_graphql_response_time_ms, response_time_ms}, state)
      when is_integer(response_time_ms) and response_time_ms >= 0 do
    {:noreply, record_linear_response_time_ms(state, response_time_ms)}
  end

  def handle_info({:linear_graphql_response_time_ms, _response_time_ms}, state),
    do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(
        {:workspace_usage_sample, refresh_ref, source, usage_result},
        %{workspace_usage_refresh_ref: refresh_ref} = state
      )
      when is_reference(refresh_ref) do
    state =
      state
      |> Map.put(:workspace_usage_refresh_ref, nil)
      |> apply_workspace_usage_result(usage_result, source)

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info({:workspace_usage_sample, _refresh_ref, _source, _usage_result}, state),
    do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp maybe_dispatch(%State{} = state) do
    state = reconcile_running_issues(state)
    state = expire_circuit_breakers(state)
    state = refresh_checkpoint_waiting_counts(state)

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      choose_issues(issues, state)
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp refresh_checkpoint_waiting_counts(%State{} = state) do
    case Tracker.fetch_issues_by_states(["Human Review"]) do
      {:ok, issues} when is_list(issues) ->
        %{state | checkpoint_waiting: classify_checkpoint_waiting(issues)}

      {:error, reason} ->
        Logger.debug("Failed to refresh checkpoint waiting counts: #{inspect(reason)}; keeping previous values")

        state
    end
  end

  defp classify_checkpoint_waiting(issues) when is_list(issues) do
    Enum.reduce(issues, @empty_checkpoint_waiting, fn issue, acc ->
      bucket =
        issue
        |> issue_labels()
        |> classify_checkpoint_bucket()

      Map.update!(acc, bucket, &(&1 + 1))
    end)
  end

  defp issue_labels(%Issue{} = issue), do: Issue.label_names(issue)
  defp issue_labels(%{labels: labels}) when is_list(labels), do: labels
  defp issue_labels(_issue), do: []

  defp classify_checkpoint_bucket(labels) when is_list(labels) do
    cond do
      has_label?(labels, "human-action") -> :human_action
      has_label?(labels, "decision-needed") -> :decision
      true -> :human_verify
    end
  end

  defp has_label?(labels, expected) when is_list(labels) and is_binary(expected) do
    normalized_expected = normalize_label(expected)
    Enum.any?(labels, &(normalize_label(&1) == normalized_expected))
  end

  defp normalize_label(label) when is_binary(label) do
    label
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_label(label), do: label |> to_string() |> normalize_label()

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec new_trace_id_for_test() :: String.t()
  def new_trace_id_for_test do
    new_trace_id()
  end

  @doc false
  @spec record_dispatch_cooldown_for_test(term(), Issue.t()) :: term()
  def record_dispatch_cooldown_for_test(%State{} = state, %Issue{} = issue) do
    record_dispatch_cooldown(state, issue)
  end

  @doc false
  @spec reset_dispatch_cooldown_for_test(term(), String.t()) :: term()
  def reset_dispatch_cooldown_for_test(%State{} = state, issue_id) when is_binary(issue_id) do
    reset_dispatch_cooldown(state, issue_id)
  end

  @doc false
  @spec check_rate_limit_circuit_breaker_for_test(term(), map(), term()) :: term()
  def check_rate_limit_circuit_breaker_for_test(%State{} = state, running_entry, reason) do
    check_rate_limit_circuit_breaker(state, running_entry, reason)
  end

  @doc false
  @spec runtime_circuit_broken_for_test(term(), Issue.t()) :: boolean()
  def runtime_circuit_broken_for_test(%State{} = state, %Issue{} = issue) do
    runtime_circuit_broken?(state, issue)
  end

  @doc false
  @spec expire_circuit_breakers_for_test(term()) :: term()
  def expire_circuit_breakers_for_test(%State{} = state) do
    expire_circuit_breakers(state)
  end

  @doc false
  @spec mark_issue_terminal_for_test(term(), String.t()) :: term()
  def mark_issue_terminal_for_test(%State{} = state, issue_id) when is_binary(issue_id) do
    mark_issue_terminal(state, issue_id)
  end

  @doc false
  @spec clear_terminal_issue_id_for_test(term(), String.t()) :: term()
  def clear_terminal_issue_id_for_test(%State{} = state, issue_id) when is_binary(issue_id) do
    clear_terminal_issue_id(state, issue_id)
  end

  @doc false
  @spec issue_waves_for_dispatch_for_test([Issue.t()]) :: [[Issue.t()]]
  def issue_waves_for_dispatch_for_test(issues) when is_list(issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    candidates = dispatch_candidates(issues, active_states, terminal_states)
    {waves, _unresolved_count} = build_issue_waves(candidates, terminal_states)
    waves
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        state
        |> clear_terminal_issue_id(issue.id)
        |> record_issue_outcome(issue.id, issue.state)
        |> reset_dispatch_cooldown(issue.id)
        |> terminate_running_issue(issue.id, true)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        state
        |> record_issue_outcome(issue.id, issue.state)
        |> terminate_running_issue(issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} = running_entry ->
        with_running_entry_logger_metadata(running_entry, fn ->
          Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")
        end)

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier)
        end

        if is_pid(pid) do
          terminate_task(pid)
        end

        if is_reference(ref) do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id)
        }

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      with_running_entry_logger_metadata(running_entry, fn ->
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")
      end)

      next_attempt = next_retry_attempt_from_running(running_entry)

      state
      |> terminate_running_issue(issue_id, false)
      |> schedule_issue_retry(issue_id, next_attempt, %{
        identifier: identifier,
        trace_id: running_entry[:trace_id],
        error: "stalled for #{elapsed_ms}ms without codex activity",
        error_class: ErrorClassifier.to_string(:transient)
      })
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    candidates = dispatch_candidates(issues, active_states, terminal_states)
    {waves, unresolved_count} = build_issue_waves(candidates, terminal_states)
    state = put_dispatch_wave_status(state, waves, unresolved_count)

    case waves do
      [current_wave | _rest] ->
        Enum.reduce(current_wave, state, fn issue, state_acc ->
          if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
            dispatch_issue(state_acc, issue)
          else
            state_acc
          end
        end)

      [] ->
        state
    end
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp dispatch_candidates(issues, active_states, terminal_states)
       when is_list(issues) and is_struct(active_states, MapSet) and
              is_struct(terminal_states, MapSet) do
    Enum.filter(issues, &candidate_issue?(&1, active_states, terminal_states))
  end

  defp dispatch_candidates(_issues, _active_states, _terminal_states), do: []

  defp build_issue_waves(issues, terminal_states)
       when is_list(issues) and is_struct(terminal_states, MapSet) do
    sorted_issues = sort_issues_for_dispatch(issues)

    issues_by_id =
      sorted_issues
      |> Enum.reduce(%{}, fn
        %Issue{id: issue_id} = issue, acc when is_binary(issue_id) ->
          Map.put(acc, issue_id, issue)

        _issue, acc ->
          acc
      end)

    ids = Map.keys(issues_by_id)

    {adjacency, indegree, externally_blocked} =
      Enum.reduce(ids, {%{}, %{}, MapSet.new()}, fn issue_id, {adj, indegree_acc, external} ->
        {
          Map.put(adj, issue_id, MapSet.new()),
          Map.put(indegree_acc, issue_id, 0),
          external
        }
      end)

    {adjacency, indegree, externally_blocked} =
      Enum.reduce(issues_by_id, {adjacency, indegree, externally_blocked}, fn
        {issue_id, %Issue{} = issue}, graph ->
          add_issue_wave_edges(graph, issue_id, issue, issues_by_id, terminal_states)

        _entry, graph ->
          graph
      end)

    build_issue_waves_loop(
      MapSet.new(ids),
      issues_by_id,
      adjacency,
      indegree,
      externally_blocked,
      []
    )
  end

  defp build_issue_waves(_issues, _terminal_states), do: {[], 0}

  defp build_issue_waves_loop(
         remaining_ids,
         issues_by_id,
         adjacency,
         indegree,
         externally_blocked,
         waves
       )
       when is_struct(remaining_ids, MapSet) and is_map(issues_by_id) and is_map(adjacency) and
              is_map(indegree) and is_struct(externally_blocked, MapSet) and is_list(waves) do
    ready_ids = wave_ready_ids(remaining_ids, indegree, externally_blocked)

    case ready_ids do
      [] ->
        {Enum.reverse(waves), MapSet.size(remaining_ids)}

      _ ->
        current_wave =
          ready_ids
          |> Enum.map(&Map.fetch!(issues_by_id, &1))
          |> sort_issues_for_dispatch()

        {remaining_ids, indegree} =
          Enum.reduce(ready_ids, {remaining_ids, indegree}, fn issue_id, {remaining_acc, indegree_acc} ->
            neighbors = Map.get(adjacency, issue_id, MapSet.new())

            indegree_acc =
              Enum.reduce(neighbors, indegree_acc, fn neighbor_id, indegree_inner ->
                Map.update(indegree_inner, neighbor_id, 0, &max(&1 - 1, 0))
              end)

            {MapSet.delete(remaining_acc, issue_id), indegree_acc}
          end)

        build_issue_waves_loop(
          remaining_ids,
          issues_by_id,
          adjacency,
          indegree,
          externally_blocked,
          [current_wave | waves]
        )
    end
  end

  defp wave_ready_ids(remaining_ids, indegree, externally_blocked)
       when is_struct(remaining_ids, MapSet) and is_map(indegree) and is_struct(externally_blocked, MapSet) do
    remaining_ids
    |> Enum.reject(&MapSet.member?(externally_blocked, &1))
    |> Enum.filter(&(Map.get(indegree, &1, 0) == 0))
  end

  defp add_issue_wave_edges(
         {adjacency, indegree, externally_blocked},
         issue_id,
         issue,
         issues_by_id,
         terminal_states
       )
       when is_binary(issue_id) and is_map(adjacency) and is_map(indegree) and
              is_struct(externally_blocked, MapSet) and is_map(issues_by_id) and
              is_struct(terminal_states, MapSet) do
    blockers =
      issue
      |> non_terminal_todo_blockers(terminal_states)
      |> Enum.uniq()

    Enum.reduce(blockers, {adjacency, indegree, externally_blocked}, fn blocker, graph ->
      case blocker do
        %{id: blocker_id} when is_binary(blocker_id) ->
          cond do
            blocker_id == issue_id ->
              {adj, ind, external} = graph
              {adj, ind, MapSet.put(external, issue_id)}

            Map.has_key?(issues_by_id, blocker_id) ->
              link_wave_dependency(graph, blocker_id, issue_id)

            true ->
              {adj, ind, external} = graph
              {adj, ind, MapSet.put(external, issue_id)}
          end

        _ ->
          {adj, ind, external} = graph
          {adj, ind, MapSet.put(external, issue_id)}
      end
    end)
  end

  defp link_wave_dependency(
         {adjacency, indegree, externally_blocked},
         blocker_id,
         issue_id
       )
       when is_binary(blocker_id) and is_binary(issue_id) and is_map(adjacency) and is_map(indegree) and
              is_struct(externally_blocked, MapSet) do
    neighbors = Map.get(adjacency, blocker_id, MapSet.new())

    if MapSet.member?(neighbors, issue_id) do
      {adjacency, indegree, externally_blocked}
    else
      adjacency = Map.put(adjacency, blocker_id, MapSet.put(neighbors, issue_id))
      indegree = Map.update(indegree, issue_id, 1, &(&1 + 1))
      {adjacency, indegree, externally_blocked}
    end
  end

  defp non_terminal_todo_blockers(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) and is_struct(terminal_states, MapSet) do
    if normalize_issue_state(issue_state) == "todo" do
      Enum.filter(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
    else
      []
    end
  end

  defp non_terminal_todo_blockers(_issue, _terminal_states), do: []

  defp put_dispatch_wave_status(%State{} = state, waves, unresolved_count)
       when is_list(waves) and is_integer(unresolved_count) and unresolved_count >= 0 do
    case waves do
      [current_wave | _rest] ->
        {current_total, current_dispatched} = dispatch_wave_progress(state, current_wave)

        %{
          state
          | dispatch_wave: %{
              current: 1,
              total: length(waves),
              current_total: current_total,
              current_dispatched: current_dispatched,
              unresolved: unresolved_count
            }
        }

      [] when unresolved_count > 0 ->
        %{
          state
          | dispatch_wave: %{
              current: nil,
              total: 0,
              current_total: 0,
              current_dispatched: 0,
              unresolved: unresolved_count
            }
        }

      [] ->
        %{state | dispatch_wave: nil}
    end
  end

  defp put_dispatch_wave_status(state, _waves, _unresolved_count), do: state

  defp dispatch_wave_progress(%State{} = state, issues) when is_list(issues) do
    issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)

    dispatched_count =
      Enum.count(issue_ids, fn issue_id ->
        MapSet.member?(state.claimed, issue_id) or Map.has_key?(state.running, issue_id)
      end)

    {length(issue_ids), dispatched_count}
  end

  defp dispatch_wave_progress(_state, _issues), do: {0, 0}

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, terminal_issue_ids: terminal_ids} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !MapSet.member?(terminal_ids, issue.id) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      dispatch_cooldown_elapsed?(state, issue) and
      !runtime_circuit_broken?(state, issue) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  # ---------------------------------------------------------------------------
  # Per-issue dispatch cooldown (exponential backoff)
  # ---------------------------------------------------------------------------

  defp dispatch_cooldown_elapsed?(%State{dispatch_cooldowns: cooldowns}, %Issue{id: issue_id, state: issue_state}) do
    case Map.get(cooldowns, issue_id) do
      nil ->
        true

      %{last_dispatched_at_ms: last_ms, attempts: attempts, last_state: last_state} ->
        if normalize_issue_state(issue_state) != normalize_issue_state(last_state) do
          # Issue changed state — cooldown no longer applies
          true
        else
          delay_ms = dispatch_cooldown_delay_ms(attempts)
          now_ms = System.monotonic_time(:millisecond)
          now_ms - last_ms >= delay_ms
        end
    end
  end

  @doc false
  @spec dispatch_cooldown_delay_ms(non_neg_integer()) :: non_neg_integer()
  def dispatch_cooldown_delay_ms(attempts) when is_integer(attempts) and attempts >= 0 do
    if attempts <= 0 do
      0
    else
      power = min(attempts - 1, 10)
      min(@dispatch_cooldown_base_ms * (1 <<< power), @dispatch_cooldown_max_ms)
    end
  end

  defp record_dispatch_cooldown(%State{dispatch_cooldowns: cooldowns} = state, %Issue{id: issue_id, state: issue_state}) do
    now_ms = System.monotonic_time(:millisecond)
    normalized = normalize_issue_state(issue_state)

    entry = Map.get(cooldowns, issue_id)

    new_entry =
      case entry do
        %{last_state: ^normalized, attempts: prev_attempts} ->
          %{last_dispatched_at_ms: now_ms, attempts: prev_attempts + 1, last_state: normalized}

        _ ->
          # First dispatch or state changed — start fresh
          %{last_dispatched_at_ms: now_ms, attempts: 1, last_state: normalized}
      end

    %{state | dispatch_cooldowns: Map.put(cooldowns, issue_id, new_entry)}
  end

  defp reset_dispatch_cooldown(%State{dispatch_cooldowns: cooldowns} = state, issue_id) do
    %{state | dispatch_cooldowns: Map.delete(cooldowns, issue_id)}
  end

  # ---------------------------------------------------------------------------
  # Rate-limit circuit breaker
  # ---------------------------------------------------------------------------

  defp check_rate_limit_circuit_breaker(%State{} = state, running_entry, reason)
       when is_map(running_entry) do
    runtime_name = Map.get(running_entry, :runtime_name)

    # Check the exit reason first (covers crash/error exits)
    {tripped?, breakers} =
      RateLimitCircuitBreaker.maybe_trip(state.circuit_breakers, runtime_name, reason)

    # If not tripped by exit reason, also check the last message from the backend
    # (covers normal exits where the output contained a rate-limit notice)
    {_tripped?, breakers} =
      if tripped? do
        {true, breakers}
      else
        last_msg = extract_last_message_text(running_entry)
        RateLimitCircuitBreaker.maybe_trip(breakers, runtime_name, last_msg)
      end

    %{state | circuit_breakers: breakers}
  end

  defp check_rate_limit_circuit_breaker(state, _running_entry, _reason), do: state

  defp extract_last_message_text(running_entry) when is_map(running_entry) do
    case Map.get(running_entry, :last_codex_message) do
      %{message: msg} when is_binary(msg) -> msg
      %{message: msg} when is_map(msg) -> inspect(msg, pretty: false, printable_limit: 4_000)
      _ -> nil
    end
  end

  defp extract_last_message_text(_running_entry), do: nil

  defp runtime_circuit_broken?(%State{circuit_breakers: breakers}, %Issue{} = issue) do
    case Config.resolve_runtime_for_issue(issue) do
      nil -> false
      %{name: name} when is_binary(name) -> RateLimitCircuitBreaker.open?(breakers, name)
      _ -> false
    end
  end

  defp expire_circuit_breakers(%State{circuit_breakers: breakers} = state) do
    %{state | circuit_breakers: RateLimitCircuitBreaker.expire_recovered(breakers)}
  end

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt) do
    case Config.resolve_runtime_for_issue(issue) do
      nil ->
        Logger.warning("No matching runtime for #{issue_context(issue)} labels=#{inspect(issue.labels)}; skipping dispatch")

        state

      runtime ->
        do_dispatch_issue_with_runtime(state, issue, attempt, runtime)
    end
  end

  defp do_dispatch_issue_with_runtime(%State{} = state, issue, attempt, runtime) do
    recipient = self()
    trace_id = new_trace_id()
    config = Config.settings!()

    Logger.info("Selected runtime=#{runtime.name} for #{issue_context(issue)}")

    with_issue_logger_metadata(issue.identifier, trace_id, fn ->
      case Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
             Logger.metadata(trace_id: trace_id, issue_identifier: issue.identifier)
             AgentRunner.run(
               issue,
               recipient,
               attempt: attempt,
               trace_id: trace_id,
               runtime: runtime,
               max_turns: config.agent.max_turns,
               active_states: config.tracker.active_states,
               context_window_tokens: config.agent.context_window_tokens
             )
           end) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          now_ms = System.monotonic_time(:millisecond)

          Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} runtime=#{runtime.name}")

          running =
            Map.put(state.running, issue.id, %{
              pid: pid,
              ref: ref,
              identifier: issue.identifier,
              issue: issue,
              trace_id: trace_id,
              session_id: nil,
              last_codex_message: nil,
              last_codex_timestamp: nil,
              last_codex_event: nil,
              codex_app_server_pid: nil,
              codex_input_tokens: 0,
              codex_output_tokens: 0,
              codex_total_tokens: 0,
              codex_last_reported_input_tokens: 0,
              codex_last_reported_output_tokens: 0,
              codex_last_reported_total_tokens: 0,
              context_window_tokens: default_context_window_tokens(),
              context_usage_percent: 0.0,
              turn_count: 0,
              retry_attempt: normalize_retry_attempt(attempt),
              started_at: DateTime.utc_now(),
              runtime_name: runtime.name
            })

          state = mark_issue_dispatch_started(state, issue.id, now_ms)
          state = record_dispatch_cooldown(state, issue)

          %{
            state
            | running: running,
              claimed: MapSet.put(state.claimed, issue.id),
              retry_attempts: Map.delete(state.retry_attempts, issue.id)
          }

        {:error, reason} ->
          Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
          next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

          schedule_issue_retry(state, issue.id, next_attempt, %{
            identifier: issue.identifier,
            trace_id: trace_id,
            error: "failed to spawn agent: #{inspect(reason)}",
            error_class: ErrorClassifier.to_string(:transient)
          })
      end
    end)
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp mark_issue_terminal(%State{terminal_issue_ids: terminal} = state, issue_id)
       when is_binary(issue_id) do
    %{state | terminal_issue_ids: MapSet.put(terminal, issue_id)}
  end

  defp clear_terminal_issue_id(%State{terminal_issue_ids: terminal} = state, issue_id)
       when is_binary(issue_id) do
    %{state | terminal_issue_ids: MapSet.delete(terminal, issue_id)}
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    error_class = pick_retry_error_class(previous_retry, metadata)
    trace_id = pick_retry_trace_id(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""
    error_class_suffix = if is_binary(error_class), do: " error_class=#{error_class}", else: ""

    with_issue_logger_metadata(identifier, trace_id, fn ->
      Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_class_suffix}#{error_suffix}")
    end)

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            trace_id: trace_id,
            error: error,
            error_class: error_class,
            delay_type: metadata[:delay_type]
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          trace_id: Map.get(retry_entry, :trace_id),
          error: Map.get(retry_entry, :error),
          error_class: Map.get(retry_entry, :error_class),
          delay_type: Map.get(retry_entry, :delay_type)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        with_issue_logger_metadata(metadata[:identifier] || issue_id, metadata[:trace_id], fn ->
          Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id}: #{inspect(reason)}")
        end)

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{
             error: "retry poll failed: #{inspect(reason)}",
             error_class: ErrorClassifier.to_string(:transient)
           })
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        with_issue_logger_metadata(issue.identifier, metadata[:trace_id], fn ->
          Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; releasing claim and removing workspace")
        end)

        cleanup_issue_workspace(issue.identifier)

        {:noreply,
         state
         |> clear_terminal_issue_id(issue_id)
         |> release_issue_claim(issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        with_issue_logger_metadata(issue.identifier, metadata[:trace_id], fn ->
          Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")
        end)

        {:noreply,
         state
         |> record_issue_outcome(issue_id, issue.state)
         |> release_issue_claim(issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, metadata) do
    with_issue_logger_metadata(metadata[:identifier] || issue_id, metadata[:trace_id], fn ->
      Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    end)

    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier)
  end

  defp cleanup_issue_workspace(_identifier), do: :ok

  defp run_workspace_housekeeping(%State{} = state, source) do
    state = maybe_schedule_workspace_usage_refresh(state, source)
    :ok = spawn_terminal_workspace_cleanup(source)
    state
  end

  defp maybe_schedule_workspace_usage_refresh(
         %State{workspace_usage_refresh_ref: refresh_ref} = state,
         _source
       )
       when is_reference(refresh_ref),
       do: state

  defp maybe_schedule_workspace_usage_refresh(%State{} = state, source) do
    refresh_ref = make_ref()
    orchestrator = self()

    Task.start(fn ->
      usage_result = Workspace.root_usage_bytes()
      send(orchestrator, {:workspace_usage_sample, refresh_ref, source, usage_result})
    end)

    %{state | workspace_usage_refresh_ref: refresh_ref}
  end

  defp spawn_terminal_workspace_cleanup(source) do
    Task.start(fn ->
      run_terminal_workspace_cleanup(source)
    end)

    :ok
  end

  defp run_terminal_workspace_cleanup(source) do
    keep_recent = workspace_cleanup_keep_recent()
    done_closed_states = done_closed_cleanup_states()

    case Tracker.fetch_issues_by_states(done_closed_states) do
      {:ok, issues} ->
        {:ok, %{removed: removed}} =
          Workspace.cleanup_completed_issue_workspaces(issues, keep_recent: keep_recent)

        if removed != [] do
          Logger.info("Workspace retention cleanup source=#{source} removed=#{length(removed)} keep_recent=#{keep_recent}")
        end

        :ok

      {:error, reason} ->
        Logger.warning("Skipping terminal workspace cleanup source=#{source}; failed to fetch terminal issues: #{inspect(reason)}")

        :ok
    end
  end

  defp done_closed_cleanup_states do
    states =
      Config.settings!().tracker.terminal_states
      |> Enum.filter(fn state_name ->
        normalize_state = normalize_issue_state(to_string(state_name))
        normalize_state in ["done", "closed"]
      end)
      |> Enum.uniq()

    if states == [] do
      ["Done", "Closed"]
    else
      states
    end
  end

  defp apply_workspace_usage_result(%State{} = state, usage_result, source) do
    warning_threshold_bytes = workspace_warning_threshold_bytes()

    case usage_result do
      {:ok, usage_bytes} when is_integer(usage_bytes) and usage_bytes >= 0 ->
        threshold_exceeded? = usage_exceeds_threshold?(usage_bytes, warning_threshold_bytes)

        maybe_log_workspace_threshold_transition(
          state.workspace_threshold_exceeded?,
          threshold_exceeded?,
          usage_bytes,
          warning_threshold_bytes,
          source
        )

        %{
          state
          | workspace_usage_bytes: usage_bytes,
            workspace_threshold_exceeded?: threshold_exceeded?
        }

      {:error, reason} ->
        Logger.warning("Failed to compute workspace disk usage source=#{source}: #{inspect(reason)}")
        state
    end
  end

  defp usage_exceeds_threshold?(usage_bytes, warning_threshold_bytes)
       when is_integer(usage_bytes) and is_integer(warning_threshold_bytes) and warning_threshold_bytes > 0 do
    usage_bytes > warning_threshold_bytes
  end

  defp usage_exceeds_threshold?(_usage_bytes, _warning_threshold_bytes), do: false

  defp maybe_log_workspace_threshold_transition(
         previous_exceeded?,
         true,
         usage_bytes,
         warning_threshold_bytes,
         source
       )
       when previous_exceeded? != true do
    Logger.warning("Workspace disk usage exceeded warning threshold source=#{source} usage_bytes=#{usage_bytes} threshold_bytes=#{warning_threshold_bytes}")
  end

  defp maybe_log_workspace_threshold_transition(
         true,
         false,
         usage_bytes,
         warning_threshold_bytes,
         source
       ) do
    Logger.info("Workspace disk usage back under threshold source=#{source} usage_bytes=#{usage_bytes} threshold_bytes=#{warning_threshold_bytes}")
  end

  defp maybe_log_workspace_threshold_transition(
         _previous_exceeded?,
         _current_exceeded?,
         _usage_bytes,
         _warning_threshold_bytes,
         _source
       ),
       do: :ok

  defp workspace_cleanup_keep_recent do
    case Config.settings!().workspace.cleanup_keep_recent do
      keep_recent when is_integer(keep_recent) and keep_recent >= 0 -> keep_recent
      _ -> 5
    end
  end

  defp workspace_warning_threshold_bytes do
    case Config.settings!().workspace.warning_threshold_bytes do
      threshold when is_integer(threshold) and threshold > 0 -> threshold
      _ -> 10 * 1024 * 1024 * 1024
    end
  end

  defp workspace_snapshot(%State{} = state) do
    keep_recent = workspace_cleanup_keep_recent()

    %{
      usage_bytes: max(0, state.workspace_usage_bytes || 0),
      warning_threshold_bytes: workspace_warning_threshold_bytes(),
      done_closed_keep_count: keep_recent,
      cleanup_keep_recent: keep_recent
    }
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, %{delay_type: :continuation} = _metadata)
       when is_integer(attempt) and attempt > @max_continuation_retries do
    Logger.warning("Max continuation retries (#{@max_continuation_retries}) reached for #{issue_context(issue)}; releasing claim")

    {:noreply,
     state
     |> record_issue_outcome(issue.id, :continuation_retries_exhausted)
     |> release_issue_claim(issue.id)}
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) do
      {:noreply, dispatch_issue(state, issue, attempt)}
    else
      with_issue_logger_metadata(issue.identifier, metadata[:trace_id], fn ->
        Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")
      end)

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots",
           error_class: ErrorClassifier.to_string(:transient)
         })
       )}
    end
  end

  defp handle_worker_failure(state, issue, issue_id, identifier, reason, error_class, failure_attempt) do
    error_class_label = ErrorClassifier.to_string(error_class)

    if ErrorClassifier.retry_allowed?(error_class, failure_attempt) do
      schedule_issue_retry(state, issue_id, failure_attempt, %{
        identifier: identifier,
        error: "agent exited: #{inspect(reason)}",
        error_class: error_class_label
      })
    else
      escalate_issue_to_human_review(
        state,
        issue,
        issue_id,
        identifier,
        reason,
        error_class_label,
        failure_attempt
      )
    end
  end

  defp escalate_issue_to_human_review(
         state,
         %Issue{id: tracker_issue_id} = issue,
         issue_id,
         identifier,
         reason,
         error_class,
         failure_attempt
       )
       when is_binary(tracker_issue_id) do
    blocker_comment = blocker_comment_body(identifier, reason, error_class, failure_attempt)

    with :ok <- Tracker.create_comment(tracker_issue_id, blocker_comment),
         :ok <- Tracker.update_issue_state(tracker_issue_id, @human_review_state) do
      Logger.warning("Escalated issue_id=#{issue_id} issue_identifier=#{identifier} to #{@human_review_state} after #{error_class} failure (attempt #{failure_attempt})")

      state
      |> complete_issue(issue_id)
      |> release_issue_claim(issue_id)
    else
      {:error, tracker_reason} ->
        Logger.error("Failed to escalate issue_id=#{issue_id} issue_identifier=#{identifier} to #{@human_review_state}: #{inspect(tracker_reason)}")

        schedule_issue_retry(state, issue_id, failure_attempt, %{
          identifier: identifier,
          error: "failed to escalate #{issue_identifier(issue, identifier)} to #{@human_review_state}: #{inspect(tracker_reason)}",
          error_class: ErrorClassifier.to_string(:transient)
        })
    end
  end

  defp escalate_issue_to_human_review(
         state,
         issue,
         issue_id,
         identifier,
         _reason,
         _error_class,
         failure_attempt
       ) do
    Logger.error("Failed to escalate issue_id=#{issue_id} issue_identifier=#{identifier} due to missing tracker issue id in running entry: #{inspect(issue)}")

    schedule_issue_retry(state, issue_id, failure_attempt, %{
      identifier: identifier,
      error: "failed to escalate #{identifier} to #{@human_review_state}: missing issue id",
      error_class: ErrorClassifier.to_string(:transient)
    })
  end

  defp blocker_comment_body(identifier, reason, error_class, failure_attempt) do
    summary = ErrorClassifier.summarize_reason(reason)

    """
    ### Blocker (auto-classified)

    - error_class: `#{error_class}`
    - failed_attempt: `#{failure_attempt}`
    - issue: `#{identifier}`
    - reason: `#{summary}`
    """
  end

  defp issue_identifier(%Issue{identifier: identifier}, _fallback) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue, fallback), do: fallback

  defp release_issue_claim(%State{} = state, issue_id) do
    %{state | claimed: MapSet.delete(state.claimed, issue_id)}
  end

  defp retry_delay(attempt, %{delay_type: :continuation})
       when is_integer(attempt) and attempt > 0 do
    min(@continuation_base_delay_ms * (1 <<< min(attempt - 1, 6)), @continuation_max_delay_ms)
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    failure_retry_delay(attempt)
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_trace_id(previous_retry, metadata) do
    metadata[:trace_id] || Map.get(previous_retry, :trace_id)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_error_class(previous_retry, metadata) do
    case metadata[:error_class] || Map.get(previous_retry, :error_class) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        if metadata[:delay_type] == :continuation do
          nil
        else
          ErrorClassifier.to_string(:transient)
        end
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp new_trace_id do
    Ecto.UUID.generate()
  end

  defp with_running_entry_logger_metadata(running_entry, fun)
       when is_map(running_entry) and is_function(fun, 0) do
    with_issue_logger_metadata(Map.get(running_entry, :identifier), Map.get(running_entry, :trace_id), fun)
  end

  defp with_running_entry_logger_metadata(_running_entry, fun) when is_function(fun, 0), do: fun.()

  defp with_issue_logger_metadata(issue_identifier, trace_id, fun) when is_function(fun, 0) do
    previous_metadata = Logger.metadata()

    metadata =
      []
      |> maybe_put_logger_metadata(:issue_identifier, issue_identifier)
      |> maybe_put_logger_metadata(:trace_id, trace_id)

    if metadata != [] do
      Logger.metadata(metadata)
    end

    try do
      fun.()
    after
      Logger.reset_metadata(previous_metadata)
    end
  end

  defp maybe_put_logger_metadata(metadata, _key, value) when value in [nil, ""], do: metadata
  defp maybe_put_logger_metadata(metadata, key, value), do: Keyword.put(metadata, key, value)

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          trace_id: Map.get(metadata, :trace_id),
          state: metadata.issue.state,
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          context_usage_percent: Map.get(metadata, :context_usage_percent),
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          runtime_name: Map.get(metadata, :runtime_name),
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          error: Map.get(retry, :error),
          error_class: Map.get(retry, :error_class)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       checkpoint_waiting: Map.get(state, :checkpoint_waiting, @empty_checkpoint_waiting),
       codex_totals: state.codex_totals,
       stats: snapshot_stats(state),
       rate_limits: Map.get(state, :codex_rate_limits),
       workspace: workspace_snapshot(state),
       wave: Map.get(state, :dispatch_wave),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)
    next_input_tokens = codex_input_tokens + token_delta.input_tokens
    next_output_tokens = codex_output_tokens + token_delta.output_tokens
    next_total_tokens = codex_total_tokens + token_delta.total_tokens

    context_window_tokens =
      extract_context_window_tokens(update) ||
        Map.get(running_entry, :context_window_tokens) ||
        default_context_window_tokens()

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        trace_id: trace_id_for_update(Map.get(running_entry, :trace_id), update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: next_input_tokens,
        codex_output_tokens: next_output_tokens,
        codex_total_tokens: next_total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        context_window_tokens: context_window_tokens,
        context_usage_percent: context_usage_percent(next_total_tokens, context_window_tokens),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, update) do
    case codex_pid_from_update(update) do
      pid when is_binary(pid) -> pid
      pid when is_integer(pid) -> Integer.to_string(pid)
      pid when is_list(pid) -> to_string(pid)
      _ -> existing
    end
  end

  defp session_id_for_update(existing, update) do
    case session_id_from_update(update) do
      session_id when is_binary(session_id) -> session_id
      _ -> existing
    end
  end

  defp turn_count_for_update(existing_count, existing_session_id, %{event: :session_started} = update)
       when is_integer(existing_count) do
    case session_id_from_update(update) do
      session_id when is_binary(session_id) ->
        if session_id == existing_session_id do
          existing_count
        else
          existing_count + 1
        end

      _ ->
        existing_count
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp trace_id_for_update(_existing, %{trace_id: trace_id}) when is_binary(trace_id),
    do: trace_id

  defp trace_id_for_update(existing, _update), do: existing

  defp session_id_from_update(%{session_id: session_id}) when is_binary(session_id), do: session_id

  defp session_id_from_update(%{payload: payload}) when is_map(payload) do
    value = Map.get(payload, :session_id) || Map.get(payload, "session_id")
    if is_binary(value), do: value
  end

  defp session_id_from_update(_update), do: nil

  defp codex_pid_from_update(%{payload: payload}) when is_map(payload) do
    Map.get(payload, :codex_app_server_pid) || Map.get(payload, "codex_app_server_pid")
  end

  defp codex_pid_from_update(_update), do: nil

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp mark_issue_dispatch_started(%State{} = state, issue_id, now_ms)
       when is_binary(issue_id) and is_integer(now_ms) do
    started = Map.get(state, :stats_issue_started_at_ms, %{})

    if Map.has_key?(started, issue_id) do
      state
    else
      %{state | stats_issue_started_at_ms: Map.put(started, issue_id, now_ms)}
    end
  end

  defp mark_issue_dispatch_started(state, _issue_id, _now_ms), do: state

  defp record_issue_outcome(%State{} = state, issue_id, issue_state) when is_binary(issue_id) do
    finalized = Map.get(state, :stats_finalized_issue_ids, MapSet.new())

    if MapSet.member?(finalized, issue_id) do
      state
    else
      case classify_issue_outcome(issue_state) do
        :completed ->
          record_completed_outcome(state, issue_id)

        :failed ->
          record_failed_outcome(state, issue_id)

        :ignored ->
          clear_issue_dispatch_started(state, issue_id)
      end
    end
  end

  defp record_issue_outcome(state, _issue_id, _issue_state), do: state

  defp classify_issue_outcome(:continuation_retries_exhausted), do: :failed

  defp classify_issue_outcome(issue_state) when is_binary(issue_state) do
    normalized = issue_state |> String.trim() |> String.downcase()

    cond do
      normalized == "" ->
        :ignored

      String.contains?(normalized, ["done", "complete", "completed", "resolved", "closed"]) ->
        :completed

      String.contains?(normalized, ["human review", "blocker", "blocked", "fail", "failed", "error", "rework"]) ->
        :failed

      true ->
        :ignored
    end
  end

  defp classify_issue_outcome(_issue_state), do: :ignored

  defp record_completed_outcome(%State{} = state, issue_id) do
    now_ms = System.monotonic_time(:millisecond)
    started = Map.get(state, :stats_issue_started_at_ms, %{})

    duration_ms =
      case Map.get(started, issue_id) do
        started_at when is_integer(started_at) -> max(0, now_ms - started_at)
        _ -> nil
      end

    durations = Map.get(state, :stats_completed_duration_ms, [])
    durations = if is_integer(duration_ms), do: prepend_limited(durations, duration_ms, @stats_max_samples), else: durations

    state
    |> Map.put(:stats_completed_count, Map.get(state, :stats_completed_count, 0) + 1)
    |> Map.put(:stats_completed_duration_ms, durations)
    |> finalize_issue_stats(issue_id)
  end

  defp record_failed_outcome(%State{} = state, issue_id) do
    state
    |> Map.put(:stats_failed_count, Map.get(state, :stats_failed_count, 0) + 1)
    |> finalize_issue_stats(issue_id)
  end

  defp finalize_issue_stats(%State{} = state, issue_id) when is_binary(issue_id) do
    finalized = Map.get(state, :stats_finalized_issue_ids, MapSet.new())

    state
    |> Map.put(:stats_finalized_issue_ids, MapSet.put(finalized, issue_id))
    |> clear_issue_dispatch_started(issue_id)
  end

  defp finalize_issue_stats(state, _issue_id), do: state

  defp clear_issue_dispatch_started(%State{} = state, issue_id) when is_binary(issue_id) do
    started = Map.get(state, :stats_issue_started_at_ms, %{})
    %{state | stats_issue_started_at_ms: Map.delete(started, issue_id)}
  end

  defp clear_issue_dispatch_started(state, _issue_id), do: state

  defp record_linear_response_time_ms(%State{} = state, response_time_ms)
       when is_integer(response_time_ms) and response_time_ms >= 0 do
    samples = Map.get(state, :stats_linear_response_time_ms, [])
    %{state | stats_linear_response_time_ms: prepend_limited(samples, response_time_ms, @stats_max_samples)}
  end

  defp record_linear_response_time_ms(state, _response_time_ms), do: state

  defp record_turn_token_usage(%State{} = state, issue_id, running_entry, update)
       when is_binary(issue_id) and is_map(running_entry) and is_map(update) do
    case extract_turn_usage(update) do
      nil ->
        state

      %{input_tokens: input_tokens, output_tokens: output_tokens, total_tokens: total_tokens} ->
        turn_entry = %{
          issue_id: issue_id,
          issue_identifier: Map.get(running_entry, :identifier),
          session_id: Map.get(running_entry, :session_id),
          turn_count: Map.get(running_entry, :turn_count, 0),
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: total_tokens,
          recorded_at: Map.get(update, :timestamp)
        }

        turn_entries = Map.get(state, :stats_turn_tokens, [])
        %{state | stats_turn_tokens: prepend_limited(turn_entries, turn_entry, @stats_max_turn_samples)}
    end
  end

  defp record_turn_token_usage(state, _issue_id, _running_entry, _update), do: state

  defp extract_turn_usage(%{event: :turn_completed} = update) do
    payload = Map.get(update, :payload) || Map.get(update, "payload") || %{}
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      usage =
        map_at_path(payload, ["usage"]) ||
          map_at_path(payload, [:usage]) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage]) ||
          map_at_path(payload, ["params", "turn", "usage"]) ||
          map_at_path(payload, [:params, :turn, :usage])

      if is_map(usage) and integer_token_map?(usage) do
        input_tokens = get_token_usage(usage, :input) || 0
        output_tokens = get_token_usage(usage, :output) || 0
        total_tokens = get_token_usage(usage, :total) || max(0, input_tokens + output_tokens)

        %{
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          total_tokens: total_tokens
        }
      end
    end
  end

  defp extract_turn_usage(_update), do: nil

  defp snapshot_stats(%State{} = state) do
    completed_count = Map.get(state, :stats_completed_count, 0)
    failed_count = Map.get(state, :stats_failed_count, 0)
    durations = Map.get(state, :stats_completed_duration_ms, []) |> Enum.reverse()
    linear_response_times = Map.get(state, :stats_linear_response_time_ms, []) |> Enum.reverse()

    %{
      completed_count: completed_count,
      failed_count: failed_count,
      success_rate: success_rate(completed_count, failed_count),
      duration_ms: %{
        sample_count: length(durations),
        p50: percentile(durations, 50),
        p95: percentile(durations, 95),
        p99: percentile(durations, 99)
      },
      per_turn_tokens: Map.get(state, :stats_turn_tokens, []),
      linear_api_response_time_ms: %{
        sample_count: length(linear_response_times),
        p50: percentile(linear_response_times, 50),
        p95: percentile(linear_response_times, 95)
      }
    }
  end

  defp success_rate(completed_count, failed_count)
       when is_integer(completed_count) and is_integer(failed_count) do
    total = completed_count + failed_count

    if total > 0 do
      completed_count / total
    else
      nil
    end
  end

  defp success_rate(_completed_count, _failed_count), do: nil

  defp percentile([], _percentile), do: nil

  defp percentile(values, percentile)
       when is_list(values) and is_number(percentile) do
    sorted = Enum.sort(values)
    count = length(sorted)
    rank = max(1, Float.ceil(percentile / 100 * count) |> trunc())
    Enum.at(sorted, rank - 1)
  end

  defp percentile(_values, _percentile), do: nil

  defp prepend_limited(list, value, limit) when is_list(list) and is_integer(limit) and limit > 0 do
    [value | list] |> Enum.take(limit)
  end

  defp prepend_limited(list, _value, _limit), do: list

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    # Codex backend wraps via to_standard_event, nesting the original payload
    # under update[:payload][:payload]. Claude stream-json nests usage under
    # payload["message"]["usage"] or payload["usage"].
    nested_payload = get_in(update, [:payload, :payload])

    claude_message_usage =
      get_in(update, [:payload, "message", "usage"]) ||
        get_in(nested_payload || %{}, ["message", "usage"])

    claude_result_usage =
      get_in(update, [:payload, "usage"]) ||
        get_in(nested_payload || %{}, ["usage"])

    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      claude_message_usage,
      claude_result_usage,
      nested_payload,
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp extract_context_window_tokens(update) do
    nested_payload = get_in(update, [:payload, :payload])

    payloads = [
      nested_payload,
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &context_window_tokens_from_payload/1)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    cond do
      integer_token_map?(payload) ->
        payload

      true ->
        absolute_paths = [
          ["params", "msg", "payload", "info", "total_token_usage"],
          [:params, :msg, :payload, :info, :total_token_usage],
          ["params", "msg", "info", "total_token_usage"],
          [:params, :msg, :info, :total_token_usage],
          ["params", "tokenUsage", "total"],
          [:params, :tokenUsage, :total],
          ["tokenUsage", "total"],
          [:tokenUsage, :total]
        ]

        explicit_map_at_paths(payload, absolute_paths)
    end
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp context_window_tokens_from_payload(payload) when is_map(payload) do
    integer_at_paths(payload, [
      ["params", "msg", "payload", "info", "model_context_window"],
      [:params, :msg, :payload, :info, :model_context_window],
      ["params", "msg", "info", "model_context_window"],
      [:params, :msg, :info, :model_context_window],
      ["params", "tokenUsage", "modelContextWindow"],
      [:params, :tokenUsage, :modelContextWindow],
      ["tokenUsage", "modelContextWindow"],
      [:tokenUsage, :modelContextWindow],
      ["model_context_window"],
      [:model_context_window],
      ["modelContextWindow"],
      [:modelContextWindow]
    ])
  end

  defp context_window_tokens_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp integer_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      payload
      |> map_at_path(path)
      |> integer_like()
    end)
  end

  defp integer_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp context_usage_percent(total_tokens, context_window_tokens)
       when is_integer(total_tokens) and total_tokens >= 0 and is_integer(context_window_tokens) and
              context_window_tokens > 0 do
    total_tokens / context_window_tokens * 100.0
  end

  defp context_usage_percent(_total_tokens, _context_window_tokens), do: nil

  defp default_context_window_tokens do
    case Config.settings!().agent.context_window_tokens do
      value when is_integer(value) and value > 0 -> value
      _ -> 400_000
    end
  end

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
