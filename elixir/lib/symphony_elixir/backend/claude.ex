defmodule SymphonyElixir.Backend.Claude do
  @moduledoc """
  Claude Code CLI backend (NDJSON over stdio).

  Each turn spawns a `claude` CLI process with `--output-format stream-json`.
  Multi-turn continuity uses `--session-id` (first turn) and `--resume` (subsequent).
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          workspace: Path.t(),
          session_id: String.t(),
          command: String.t(),
          permission_mode: String.t(),
          mcp_config_path: Path.t() | nil,
          turn_timeout_ms: pos_integer(),
          resumed: boolean()
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, settings} <- claude_runtime_settings(opts) do
      session_id = generate_session_id()

      mcp_config_path =
        case settings.mcp_servers do
          [] -> nil
          servers -> write_mcp_config(expanded_workspace, servers)
        end

      {:ok,
       %{
         workspace: expanded_workspace,
         session_id: session_id,
         command: settings.command,
         permission_mode: settings.permission_mode,
         mcp_config_path: mcp_config_path,
         turn_timeout_ms: settings.turn_timeout_ms,
         resumed: false
       }}
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = "turn-#{System.unique_integer([:positive])}"

    emit_message(on_message, :session_started, %{
      session_id: session.session_id,
      turn_id: turn_id
    })

    Logger.info(
      "Claude session starting for #{issue_context(issue)} session_id=#{session.session_id} turn_id=#{turn_id}"
    )

    cli_args = build_cli_args(session, prompt)

    case run_cli(session.workspace, session.command, cli_args, on_message, session.turn_timeout_ms) do
      {:ok, result} ->
        Logger.info(
          "Claude session completed for #{issue_context(issue)} session_id=#{session.session_id}"
        )

        {:ok,
         %{
           result: result,
           session_id: session.session_id,
           turn_id: turn_id,
           next_session: %{session | resumed: true}
         }}

      {:error, reason} ->
        Logger.warning(
          "Claude session failed for #{issue_context(issue)} session_id=#{session.session_id}: #{inspect(reason)}"
        )

        emit_message(on_message, :turn_ended_with_error, %{
          session_id: session.session_id,
          reason: reason
        })

        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{mcp_config_path: nil}), do: :ok

  def stop_session(%{mcp_config_path: path}) when is_binary(path) do
    File.rm(path)
    :ok
  end

  def stop_session(_session), do: :ok

  # -- CLI execution --

  defp build_cli_args(session, prompt) do
    base = [
      "-p", prompt,
      "--output-format", "stream-json",
      "--verbose",
      "--permission-mode", session.permission_mode
    ]

    session_args =
      if session.resumed do
        ["--resume", session.session_id]
      else
        ["--session-id", session.session_id]
      end

    mcp_args =
      case session.mcp_config_path do
        nil -> []
        path -> ["--mcp-config", path]
      end

    session_args ++ base ++ mcp_args
  end

  defp run_cli(workspace, command, args, on_message, turn_timeout_ms) do
    executable = resolve_executable(command)

    case executable do
      {:error, reason} ->
        {:error, reason}

      {:ok, exe, base_args} ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(exe)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: Enum.map(base_args ++ args, &String.to_charlist/1),
              cd: String.to_charlist(workspace),
              line: @port_line_bytes
            ]
          )

        await_completion(port, on_message, turn_timeout_ms, "")
    end
  end

  defp resolve_executable(command) do
    parts = String.split(command, ~r/\s+/, trim: true)

    case parts do
      [] ->
        {:error, :empty_claude_command}

      [cmd | rest] ->
        case System.find_executable(cmd) do
          nil -> {:error, {:claude_cli_not_found, cmd}}
          path -> {:ok, path, rest}
        end
    end
  end

  defp await_completion(port, on_message, timeout_ms, pending) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending <> to_string(chunk)
        handle_line(port, on_message, line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        await_completion(port, on_message, timeout_ms, pending <> to_string(chunk))

      {^port, {:exit_status, 0}} ->
        {:ok, %{"exit_status" => 0}}

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        safe_close_port(port)
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, on_message, line, timeout_ms) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result", "subtype" => "success"} = payload} ->
        emit_message(on_message, :turn_completed, %{payload: payload, raw: line})
        # Wait for port exit after result
        await_exit(port, payload)

      {:ok, %{"type" => "result", "subtype" => "error"} = payload} ->
        emit_message(on_message, :turn_failed, %{payload: payload, raw: line})
        await_exit(port, nil)
        {:error, {:turn_failed, Map.get(payload, "error", "unknown")}}

      {:ok, %{"type" => type} = payload} ->
        event = map_event_type(type)
        emit_message(on_message, event, %{payload: payload, raw: line})
        await_completion(port, on_message, timeout_ms, "")

      {:ok, payload} ->
        emit_message(on_message, :other_message, %{payload: payload, raw: line})
        await_completion(port, on_message, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_line(line)
        await_completion(port, on_message, timeout_ms, "")
    end
  end

  defp await_exit(port, result) do
    receive do
      {^port, {:exit_status, 0}} -> {:ok, result || %{"exit_status" => 0}}
      {^port, {:exit_status, _status}} -> {:ok, result || %{"exit_status" => 0}}
      {^port, {:data, _data}} -> await_exit(port, result)
    after
      5_000 ->
        safe_close_port(port)
        {:ok, result || %{"exit_status" => 0}}
    end
  end

  defp map_event_type("system"), do: :system_init
  defp map_event_type("assistant"), do: :agent_message
  defp map_event_type("tool_use"), do: :tool_call
  defp map_event_type("tool_result"), do: :tool_result
  defp map_event_type("content_delta"), do: :message_delta
  defp map_event_type("turn_started"), do: :turn_started
  defp map_event_type(_other), do: :other_message

  # -- MCP config --

  defp write_mcp_config(workspace, servers) do
    config_dir = Path.join(workspace, ".symphony-claude")
    File.mkdir_p!(config_dir)
    path = Path.join(config_dir, "mcp-#{System.unique_integer([:positive])}.json")

    mcp_map =
      servers
      |> Enum.reduce(%{}, fn server, acc ->
        server = stringify_keys(server)

        case Map.get(server, "name") do
          name when is_binary(name) and name != "" ->
            Map.put(acc, name, Map.delete(server, "name"))

          _ ->
            acc
        end
      end)

    File.write!(path, Jason.encode!(%{"mcpServers" => mcp_map}, pretty: true))
    path
  end

  # -- Workspace validation (shared pattern) --

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error,
           {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  # -- Config --

  @default_command "claude"
  @default_permission_mode "bypassPermissions"

  defp claude_runtime_settings(opts) do
    with {:ok, settings} <- Config.settings() do
      {:ok,
       %{
         command: Keyword.get(opts, :command, @default_command),
         permission_mode: Keyword.get(opts, :permission_mode, @default_permission_mode),
         mcp_servers: settings.codex.opencode_mcp_servers,
         turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, settings.codex.turn_timeout_ms)
       }}
    end
  end

  # -- Helpers --

  defp generate_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
    |> String.downcase()
  end

  defp emit_message(on_message, event, details) when is_function(on_message, 1) do
    message = details |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp issue_context(_issue), do: "unknown_issue"

  defp safe_close_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined -> :ok
      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  defp log_non_json_line(data) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude CLI output: #{text}")
      else
        Logger.debug("Claude CLI output: #{text}")
      end
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key =
        case key do
          k when is_binary(k) -> k
          k when is_atom(k) -> Atom.to_string(k)
          other -> to_string(other)
        end

      normalized_value =
        cond do
          is_map(value) -> stringify_keys(value)
          is_list(value) -> Enum.map(value, &stringify_keys/1)
          true -> value
        end

      Map.put(acc, normalized_key, normalized_value)
    end)
  end

  defp stringify_keys(value), do: value
end
