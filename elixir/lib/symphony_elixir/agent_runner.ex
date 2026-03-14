defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.{Config, ErrorClassifier, Linear.Issue, PromptBuilder, Tracker, Workspace}

  defmodule RunError do
    @moduledoc false
    defexception [:message, :issue_id, :issue_identifier, :error_class, :reason]
  end

  @empty_turn_threshold_ms 5_000
  @max_consecutive_empty_turns 3
  @empty_turn_backoff_base_ms 2_000
  @type error_class :: ErrorClassifier.error_class()

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    trace_id = issue_trace_id(issue, opts)
    issue = attach_trace_id(issue, trace_id)
    opts = maybe_put_trace_id_opt(opts, trace_id)

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
    default_max_turns = Config.settings!().agent.max_turns
    max_turns = runtime_max_turns(runtime, default_max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    trace_id = issue_trace_id(issue, opts)

    session_opts =
      runtime_session_opts(runtime)
      |> Keyword.merge(issue: issue, trace_id: trace_id)

    with {:ok, session} <- AppServer.start_session(workspace, session_opts) do
      try do
        do_run_codex_turns(session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, 1, max_turns, 0)
      after
        AppServer.stop_session(session)
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
      turn_timeout_ms: runtime.turn_timeout_ms,
      read_timeout_ms: runtime.read_timeout_ms
    ]
  end

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns, consecutive_empty) do
    turn_start_ms = System.monotonic_time(:millisecond)
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           AppServer.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue, issue_trace_id(issue, opts)),
             trace_id: issue_trace_id(issue, opts)
           ) do
      turn_elapsed_ms = System.monotonic_time(:millisecond) - turn_start_ms
      empty_turn? = turn_elapsed_ms < @empty_turn_threshold_ms

      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns} elapsed_ms=#{turn_elapsed_ms}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          next_consecutive_empty = if empty_turn?, do: consecutive_empty + 1, else: 0

          if next_consecutive_empty >= @max_consecutive_empty_turns do
            Logger.warning(
              "Empty turn circuit breaker: #{next_consecutive_empty} consecutive empty turns (<#{@empty_turn_threshold_ms}ms) for #{issue_context(refreshed_issue)}; returning control to orchestrator"
            )

            :ok
          else
            if empty_turn? do
              backoff_ms = @empty_turn_backoff_base_ms * Bitwise.bsl(1, min(next_consecutive_empty - 1, 4))
              Logger.info("Empty turn detected for #{issue_context(refreshed_issue)} turn=#{turn_number}/#{max_turns}; backing off #{backoff_ms}ms")
              Process.sleep(backoff_ms)
            end

            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              app_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns,
              next_consecutive_empty
            )
          end

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

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

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
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

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

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

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
