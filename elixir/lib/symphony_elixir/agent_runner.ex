defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with the configured backend.
  """

  require Logger
  alias SymphonyElixir.{AgentBackend, ErrorClassifier, Linear.Issue, PromptBuilder, Tracker, Workspace}

  defmodule RunError do
    @moduledoc false
    defexception [:message, :issue_id, :issue_identifier, :error_class, :reason]
  end

  @empty_turn_threshold_ms 5_000
  @max_consecutive_empty_turns 3
  @max_total_empty_turns 5
  @empty_turn_ratio_window 5
  @empty_turn_ratio_threshold 0.6
  @empty_turn_backoff_base_ms 2_000
  @default_agent_max_turns 20
  @default_active_states ["Todo", "In Progress"]
  @default_context_window_tokens 400_000
  @type error_class :: ErrorClassifier.error_class()
  @context_warning_remaining_ratio 0.35
  @context_critical_remaining_ratio 0.25

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    trace_id = issue_trace_id(issue, opts)
    issue = attach_trace_id(issue, trace_id)
    opts = opts |> maybe_put_trace_id_opt(trace_id) |> inject_default_runner_options()

    with_issue_logger_metadata(issue, trace_id, fn ->
      Logger.info("Starting agent run for #{issue_context(issue)}")

      case Workspace.create_for_issue(issue) do
        {:ok, workspace} ->
          try do
            with :ok <- Workspace.run_before_run_hook(workspace, issue, trace_id: trace_id),
                 :ok <- run_codex_turns(workspace, issue, codex_update_recipient, opts) do
              :ok
            else
              {:error, reason} ->
                raise_run_error(issue, reason)
            end
          after
            Workspace.run_after_run_hook(workspace, issue, trace_id: trace_id)
          end

        {:error, reason} ->
          raise_run_error(issue, reason)
      end
    end)
  end

  @doc false
  @spec classify_error_for_test(term()) :: error_class()
  def classify_error_for_test(reason), do: ErrorClassifier.classify(reason)

  defp codex_message_handler(recipient, issue, trace_id) do
    fn message ->
      maybe_track_latest_usage(message)
      send_codex_update(recipient, issue, message, trace_id)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message, trace_id)
       when is_binary(issue_id) and is_pid(recipient) do
    message =
      if is_binary(trace_id) do
        Map.put_new(message, :trace_id, trace_id)
      else
        message
      end

    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message, _trace_id), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts) do
    runtime = Keyword.get(opts, :runtime)
    default_max_turns = Keyword.get(opts, :max_turns, @default_agent_max_turns)
    max_turns = runtime_max_turns(runtime, default_max_turns)
    context_monitor = init_context_monitor(opts)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    active_states = runner_active_states(opts)
    trace_id = issue_trace_id(issue, opts)

    session_opts =
      runtime_session_opts(runtime)
      |> Keyword.merge(issue: issue, trace_id: trace_id)

    with {:ok, backend} <- resolve_backend(opts),
         {:ok, session} <- backend.start_session(workspace, session_opts) do
      try do
        do_run_codex_turns(
          backend,
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          active_states,
          1,
          max_turns,
          0,
          0,
          context_monitor
        )
      after
        backend.stop_session(session)
      end
    end
  end

  defp runtime_max_turns(nil, default), do: default
  defp runtime_max_turns(%{max_turns: mt}, _default) when is_integer(mt) and mt > 0, do: mt
  defp runtime_max_turns(_runtime, default), do: default

  defp runtime_session_opts(nil), do: []

  defp runtime_session_opts(runtime) do
    [
      command: runtime.command,
      approval_policy: runtime.approval_policy,
      thread_sandbox: runtime.thread_sandbox,
      turn_sandbox_policy: runtime.turn_sandbox_policy,
      permission_mode: runtime.permission_mode,
      turn_timeout_ms: runtime.turn_timeout_ms,
      read_timeout_ms: runtime.read_timeout_ms,
      stall_timeout_ms: runtime.stall_timeout_ms
    ]
  end

  defp do_run_codex_turns(
         backend,
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         active_states,
         turn_number,
         max_turns,
         consecutive_empty,
         total_empty,
         context_monitor
       ) do
    turn_start_ms = System.monotonic_time(:millisecond)
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    prompt_suffix = context_prompt_suffix(context_monitor)
    Process.put(:agent_runner_latest_usage, nil)

    with {:ok, turn_session} <-
           backend.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue, issue_trace_id(issue, opts)),
             trace_id: issue_trace_id(issue, opts),
             prompt_suffix: prompt_suffix
           ) do
      turn_session =
        Map.put(
          turn_session,
          :usage,
          Process.get(:agent_runner_latest_usage)
        )

      Process.delete(:agent_runner_latest_usage)
      next_app_session = Map.get(turn_session, :next_session, app_session)
      next_context_monitor = update_context_monitor(context_monitor, turn_session[:usage])

      turn_elapsed_ms = System.monotonic_time(:millisecond) - turn_start_ms
      empty_turn? = turn_elapsed_ms < @empty_turn_threshold_ms

      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns} elapsed_ms=#{turn_elapsed_ms}")

      case continue_with_issue?(issue, issue_state_fetcher, active_states) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          next_consecutive_empty = if empty_turn?, do: consecutive_empty + 1, else: 0
          next_total_empty = if empty_turn?, do: total_empty + 1, else: total_empty

          # Sliding window: track recent turns for ratio check
          recent_window = min(turn_number, @empty_turn_ratio_window)
          empty_ratio = if recent_window > 0, do: next_consecutive_empty / recent_window, else: 0.0

          cond do
            next_consecutive_empty >= @max_consecutive_empty_turns ->
              Logger.warning(
                "Empty turn circuit breaker: #{next_consecutive_empty} consecutive empty turns (<#{@empty_turn_threshold_ms}ms) for #{issue_context(refreshed_issue)}; returning control to orchestrator"
              )

              :ok

            next_total_empty >= @max_total_empty_turns ->
              Logger.warning(
                "Empty turn circuit breaker: #{next_total_empty} total empty turns for #{issue_context(refreshed_issue)}; returning control to orchestrator"
              )

              :ok

            recent_window >= @empty_turn_ratio_window and empty_ratio >= @empty_turn_ratio_threshold ->
              Logger.warning(
                "Empty turn circuit breaker: #{Float.round(empty_ratio * 100, 1)}% empty in last #{recent_window} turns for #{issue_context(refreshed_issue)}; returning control to orchestrator"
              )

              :ok

            true ->
              if empty_turn? do
                backoff_ms = @empty_turn_backoff_base_ms * Bitwise.bsl(1, min(next_consecutive_empty - 1, 4))
                Logger.info("Empty turn detected for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{max_turns}; backing off #{backoff_ms}ms")
                Process.sleep(backoff_ms)
              end

              Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

                do_run_codex_turns(
                  backend,
                  next_app_session,
                  workspace,
                  refreshed_issue,
                  codex_update_recipient,
                  opts,
                  issue_state_fetcher,
                  active_states,
                  turn_number + 1,
                  max_turns,
                  next_consecutive_empty,
                  next_total_empty,
                  next_context_monitor
              )
          end

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, refreshed_issue} ->
          notify_issue_terminal(codex_update_recipient, issue, refreshed_issue)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp notify_issue_terminal(recipient, %Issue{id: issue_id}, %Issue{state: state_name})
       when is_pid(recipient) and is_binary(issue_id) and is_binary(state_name) do
    send(recipient, {:agent_issue_terminal, issue_id, state_name})
  end

  defp notify_issue_terminal(_recipient, _issue, _refreshed_issue), do: :ok

  defp resolve_backend(opts) do
    runtime = Keyword.get(opts, :runtime)

    case runtime do
      nil ->
        AgentBackend.resolve_provider("codex")

      %{provider: provider} ->
        AgentBackend.resolve_provider(provider)
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns) do
    attempt = Keyword.get(opts, :attempt)

    if is_integer(attempt) and attempt > 1 do
      build_continuation_retry_prompt(issue, attempt)
    else
      PromptBuilder.build_prompt(issue, opts)
    end
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp build_continuation_retry_prompt(issue, attempt) do
    """
    Continuation retry (attempt #{attempt}):

    - Issue: #{issue.identifier} — #{issue.title}
    - The previous session ended, but this issue is still active.
    - Read the workpad (WORKPAD.md) in the workspace to understand current progress.
    - Resume from where the previous session left off; do not restart from scratch.
    - Focus only on remaining acceptance criteria that are not yet marked done.
    - If truly blocked, update the workpad with the blocker and stop.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher, active_states) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state, active_states) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher, _active_states), do: {:done, issue}

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name, _active_states), do: false

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp raise_run_error(issue, reason) do
    context = issue_context(issue)
    error_class = ErrorClassifier.classify(reason)

    message = "Agent run failed for #{context} error_class=#{error_class}: #{inspect(reason)}"

    Logger.error(message)

    raise RunError,
      message: message,
      issue_id: issue_id(issue),
      issue_identifier: issue_identifier(issue),
      error_class: error_class,
      reason: reason
  end

  defp issue_id(%Issue{id: issue_id}) when is_binary(issue_id), do: issue_id
  defp issue_id(_issue), do: nil

  defp issue_identifier(%Issue{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: nil

  defp issue_trace_id(issue, opts) when is_list(opts) do
    Keyword.get(opts, :trace_id) || issue_trace_id(issue)
  end

  defp issue_trace_id(%{trace_id: trace_id}) when is_binary(trace_id) and trace_id != "", do: trace_id
  defp issue_trace_id(_issue), do: nil

  defp attach_trace_id(%Issue{} = issue, trace_id) when is_binary(trace_id),
    do: Map.put(issue, :trace_id, trace_id)

  defp attach_trace_id(issue, _trace_id), do: issue

  defp maybe_put_trace_id_opt(opts, trace_id) when is_binary(trace_id),
    do: Keyword.put(opts, :trace_id, trace_id)

  defp maybe_put_trace_id_opt(opts, _trace_id), do: opts

  defp with_issue_logger_metadata(issue, trace_id, fun) when is_function(fun, 0) do
    previous_metadata = Logger.metadata()

    metadata =
      []
      |> maybe_put_logger_metadata(:issue_identifier, Map.get(issue, :identifier))
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

  defp inject_default_runner_options(opts) when is_list(opts) do
    opts
    |> Keyword.put_new(:max_turns, @default_agent_max_turns)
    |> Keyword.put_new(:context_window_tokens, @default_context_window_tokens)
    |> Keyword.put_new(:active_states, @default_active_states)
  end

  defp runner_active_states(opts) when is_list(opts) do
    opts
    |> Keyword.get(:active_states, @default_active_states)
    |> normalize_runner_active_states()
  end

  defp normalize_runner_active_states(active_states) when is_list(active_states) do
    active_states
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
  end

  defp normalize_runner_active_states(_active_states), do: @default_active_states

  defp init_context_monitor(opts) when is_list(opts) do
    context_window_tokens =
      opts
      |> Keyword.get(:context_window_tokens, @default_context_window_tokens)
      |> positive_integer_or(400_000)

    warning_remaining_ratio =
      opts
      |> Keyword.get(:context_warning_remaining_ratio, @context_warning_remaining_ratio)
      |> ratio_or(@context_warning_remaining_ratio)

    critical_remaining_ratio =
      opts
      |> Keyword.get(:context_critical_remaining_ratio, @context_critical_remaining_ratio)
      |> ratio_or(@context_critical_remaining_ratio)

    %{
      context_window_tokens: context_window_tokens,
      warning_remaining_ratio: warning_remaining_ratio,
      critical_remaining_ratio: critical_remaining_ratio,
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      reported_input_tokens: 0,
      reported_output_tokens: 0,
      reported_total_tokens: 0,
      usage_ratio: 0.0,
      alert_level: :normal
    }
  end

  defp context_prompt_suffix(%{alert_level: :warning} = context_monitor) do
    """
    Context budget WARNING:

    - Context used: #{format_usage_percent(context_monitor.usage_ratio)} (#{context_monitor.total_tokens}/#{context_monitor.context_window_tokens} tokens).
    - Remaining budget is low. Stay concise and avoid broad re-analysis.
    - Focus only on unresolved acceptance criteria.
    """
  end

  defp context_prompt_suffix(%{alert_level: :critical} = context_monitor) do
    """
    Context budget CRITICAL:

    - Context used: #{format_usage_percent(context_monitor.usage_ratio)} (#{context_monitor.total_tokens}/#{context_monitor.context_window_tokens} tokens).
    - Enter convergence mode immediately:
      1. Finish the current in-flight task only.
      2. Commit completed changes.
      3. Update the workpad with final validation evidence.
      4. Stop and do not start additional tasks.
    """
  end

  defp context_prompt_suffix(_context_monitor), do: nil

  defp maybe_track_latest_usage(message) when is_map(message) do
    case extract_token_usage(message) do
      usage when is_map(usage) and map_size(usage) > 0 ->
        Process.put(:agent_runner_latest_usage, usage)

      _ ->
        :ok
    end

    :ok
  end

  defp maybe_track_latest_usage(_message), do: :ok

  defp update_context_monitor(context_monitor, usage) when is_map(context_monitor) do
    input_progress =
      compute_token_progress(
        usage,
        :input,
        Map.get(context_monitor, :reported_input_tokens, 0)
      )

    output_progress =
      compute_token_progress(
        usage,
        :output,
        Map.get(context_monitor, :reported_output_tokens, 0)
      )

    total_progress =
      compute_token_progress(
        usage,
        :total,
        Map.get(context_monitor, :reported_total_tokens, 0)
      )

    input_tokens = Map.get(context_monitor, :input_tokens, 0) + input_progress.delta
    output_tokens = Map.get(context_monitor, :output_tokens, 0) + output_progress.delta
    total_tokens = Map.get(context_monitor, :total_tokens, 0) + total_progress.delta

    context_window_tokens = Map.get(context_monitor, :context_window_tokens, 400_000)
    usage_ratio = total_tokens / context_window_tokens

    alert_level =
      context_alert_level(
        usage_ratio,
        Map.get(context_monitor, :warning_remaining_ratio, @context_warning_remaining_ratio),
        Map.get(context_monitor, :critical_remaining_ratio, @context_critical_remaining_ratio)
      )

    %{
      context_monitor
      | input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: total_tokens,
        reported_input_tokens: input_progress.reported_total,
        reported_output_tokens: output_progress.reported_total,
        reported_total_tokens: total_progress.reported_total,
        usage_ratio: usage_ratio,
        alert_level: alert_level
    }
  end

  defp compute_token_progress(usage, token_kind, previous_total) do
    reported_total = get_token_usage(usage, token_kind)

    delta =
      if is_integer(reported_total) and reported_total >= previous_total do
        reported_total - previous_total
      else
        0
      end

    %{
      delta: delta,
      reported_total:
        if is_integer(reported_total) and reported_total >= 0 do
          reported_total
        else
          previous_total
        end
    }
  end

  defp context_alert_level(usage_ratio, warning_remaining_ratio, critical_remaining_ratio)
       when is_number(usage_ratio) do
    remaining_ratio = max(0.0, 1.0 - usage_ratio)

    cond do
      remaining_ratio <= critical_remaining_ratio -> :critical
      remaining_ratio <= warning_remaining_ratio -> :warning
      true -> :normal
    end
  end

  defp context_alert_level(_usage_ratio, _warning_remaining_ratio, _critical_remaining_ratio),
    do: :normal

  defp extract_token_usage(message) when is_map(message) do
    # The Codex backend wraps messages via to_standard_event, nesting the original
    # payload under message[:payload][:payload]. Include that path for extraction.
    nested_payload = get_in(message, [:payload, :payload])

    # Claude stream-json nests usage under payload["message"]["usage"] (assistant events)
    # and payload["usage"] (result events).
    claude_message_usage = get_in(message, [:payload, "message", "usage"])
    claude_result_usage = get_in(message, [:payload, "usage"])

    payloads = [
      message[:usage],
      Map.get(message, "usage"),
      Map.get(message, :usage),
      claude_message_usage,
      claude_result_usage,
      nested_payload,
      message[:payload],
      Map.get(message, "payload"),
      Map.get(message, :payload),
      message
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_token_usage(_message), do: %{}

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
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

  defp absolute_token_usage_from_payload(_payload), do: nil

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

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

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
      value = map_integer_value(payload, field)
      !is_nil(value)
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

  defp map_integer_value(payload, field) when is_map(payload) do
    payload
    |> Map.get(field)
    |> integer_like()
  end

  defp map_integer_value(_payload, _field), do: nil

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _rest} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil

  defp positive_integer_or(value, _fallback) when is_integer(value) and value > 0, do: value
  defp positive_integer_or(_value, fallback), do: fallback

  defp ratio_or(value, _fallback) when is_number(value) and value >= 0 and value <= 1, do: value
  defp ratio_or(_value, fallback), do: fallback

  defp format_usage_percent(value) when is_number(value) do
    value
    |> Kernel.*(100.0)
    |> Float.round(1)
    |> :erlang.float_to_binary(decimals: 1)
    |> Kernel.<>("%")
  end

  defp format_usage_percent(_value), do: "0.0%"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
