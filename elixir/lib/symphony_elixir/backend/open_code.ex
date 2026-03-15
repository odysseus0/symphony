defmodule SymphonyElixir.Backend.OpenCode do
  @moduledoc """
  OpenCode ACP backend (JSON-RPC over stdio).
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @initialize_id 1
  @session_new_id 2
  @session_prompt_id 3
  @protocol_version 1
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          port: port(),
          metadata: map(),
          workspace: Path.t(),
          runtime_dir: Path.t(),
          session_id: String.t(),
          read_timeout_ms: pos_integer(),
          turn_timeout_ms: pos_integer()
        }

  @default_command "opencode acp"

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, settings} <- opencode_runtime_settings(opts),
         {:ok, runtime_dir} <- write_runtime_config(expanded_workspace, settings.mcp_servers),
         {:ok, port} <- start_port(runtime_dir, settings.command) do
      metadata = port_metadata(port)

      with :ok <- send_initialize(port, settings.read_timeout_ms),
           {:ok, session_id} <-
             create_session(port, expanded_workspace, settings.mcp_servers, settings.read_timeout_ms) do
        {:ok,
         %{
           port: port,
           metadata: metadata,
           workspace: expanded_workspace,
           runtime_dir: runtime_dir,
           session_id: session_id,
           read_timeout_ms: settings.read_timeout_ms,
           turn_timeout_ms: settings.turn_timeout_ms
         }}
      else
        {:error, reason} ->
          stop_port(port)
          cleanup_runtime_dir(runtime_dir)
          {:error, reason}
      end
    end
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{
          port: port,
          metadata: metadata,
          session_id: opencode_session_id,
          read_timeout_ms: read_timeout_ms,
          turn_timeout_ms: turn_timeout_ms
        },
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    turn_id = "prompt-#{System.unique_integer([:positive])}"
    session_id = "#{opencode_session_id}-#{turn_id}"

    emit_message(
      on_message,
      :session_started,
      %{
        session_id: session_id,
        thread_id: opencode_session_id,
        turn_id: turn_id
      },
      metadata
    )

    Logger.info("OpenCode session started for #{issue_context(issue)} session_id=#{session_id}")

    :ok = prompt_session(port, opencode_session_id, prompt, read_timeout_ms)

    case await_turn_completion(
           port,
           on_message,
           turn_timeout_ms,
           read_timeout_ms,
           "",
           opencode_session_id
         ) do
      {:ok, result} ->
        Logger.info("OpenCode session completed for #{issue_context(issue)} session_id=#{session_id}")

        {:ok,
         %{
           result: result,
           session_id: session_id,
           thread_id: opencode_session_id,
           turn_id: turn_id
         }}

      {:error, reason} ->
        Logger.warning("OpenCode session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(
          on_message,
          :turn_ended_with_error,
          %{session_id: session_id, reason: reason},
          metadata
        )

        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port, runtime_dir: runtime_dir}) do
    stop_port(port)
    cleanup_runtime_dir(runtime_dir)
    :ok
  end

  defp opencode_runtime_settings(opts) do
    with {:ok, settings} <- Config.settings() do
      {:ok,
       %{
         command: Keyword.get(opts, :command, @default_command),
         mcp_servers: settings.codex.opencode_mcp_servers,
         turn_timeout_ms: Keyword.get(opts, :turn_timeout_ms, settings.codex.turn_timeout_ms),
         read_timeout_ms: Keyword.get(opts, :read_timeout_ms, settings.codex.read_timeout_ms)
       }}
    end
  end

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
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp start_port(runtime_dir, command) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(runtime_dir),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp write_runtime_config(workspace, mcp_servers) do
    runtime_dir =
      Path.join([
        workspace,
        ".symphony-opencode",
        Integer.to_string(System.unique_integer([:positive]))
      ])

    with :ok <- File.mkdir_p(runtime_dir),
         :ok <-
           File.write(
             Path.join(runtime_dir, "opencode.json"),
             Jason.encode!(runtime_config_payload(mcp_servers), pretty: true)
           ) do
      {:ok, runtime_dir}
    else
      {:error, reason} ->
        {:error, {:opencode_runtime_config_write_failed, runtime_dir, reason}}
    end
  end

  defp cleanup_runtime_dir(path) when is_binary(path), do: File.rm_rf(path)
  defp cleanup_runtime_dir(_path), do: :ok

  defp runtime_config_payload(mcp_servers) do
    mcp =
      mcp_servers
      |> normalize_mcp_servers()
      |> Enum.reduce(%{}, fn server, acc ->
        case Map.get(server, "name") do
          name when is_binary(name) and name != "" ->
            Map.put(acc, name, Map.delete(server, "name"))

          _ ->
            acc
        end
      end)

    %{
      "$schema" => "https://opencode.ai/config.json",
      "mcp" => mcp
    }
  end

  defp send_initialize(port, read_timeout_ms) do
    send_message(port, %{
      "id" => @initialize_id,
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "params" => %{"protocolVersion" => @protocol_version}
    })

    case await_response(port, @initialize_id, read_timeout_ms) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_session(port, workspace, mcp_servers, read_timeout_ms) do
    send_message(port, %{
      "id" => @session_new_id,
      "jsonrpc" => "2.0",
      "method" => "session/new",
      "params" => %{
        "cwd" => workspace,
        "mcpServers" => normalize_mcp_servers(mcp_servers)
      }
    })

    case await_response(port, @session_new_id, read_timeout_ms) do
      {:ok, %{"sessionId" => session_id}} when is_binary(session_id) and session_id != "" ->
        {:ok, session_id}

      {:ok, payload} ->
        {:error, {:invalid_session_payload, payload}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prompt_session(port, session_id, prompt, read_timeout_ms) do
    send_message(port, %{
      "id" => @session_prompt_id,
      "jsonrpc" => "2.0",
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => prompt}]
      }
    })

    # keep return shape aligned with the existing backend contract
    _ = read_timeout_ms
    :ok
  end

  defp await_turn_completion(port, on_message, turn_timeout_ms, read_timeout_ms, pending_line, session_id) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        line = pending_line <> to_string(chunk)
        handle_turn_line(port, on_message, line, turn_timeout_ms, read_timeout_ms, session_id)

      {^port, {:data, {:noeol, chunk}}} ->
        await_turn_completion(
          port,
          on_message,
          turn_timeout_ms,
          read_timeout_ms,
          pending_line <> to_string(chunk),
          session_id
        )

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      turn_timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_turn_line(port, on_message, payload_string, turn_timeout_ms, read_timeout_ms, session_id) do
    case Jason.decode(payload_string) do
      {:ok, %{"id" => @session_prompt_id, "result" => result} = payload} ->
        emit_message(
          on_message,
          :turn_completed,
          %{payload: payload, raw: payload_string, details: result},
          metadata_from_message(port, payload)
        )

        {:ok, result}

      {:ok, %{"id" => @session_prompt_id, "error" => error} = payload} ->
        emit_message(
          on_message,
          :turn_failed,
          %{payload: payload, raw: payload_string, details: error},
          metadata_from_message(port, payload)
        )

        {:error, {:turn_failed, error}}

      {:ok, %{"method" => "session/update"} = payload} ->
        emit_message(
          on_message,
          :notification,
          %{payload: payload, raw: payload_string},
          metadata_from_message(port, payload)
        )

        maybe_emit_opencode_update_event(on_message, payload, payload_string, port, session_id)

        await_turn_completion(port, on_message, turn_timeout_ms, read_timeout_ms, "", session_id)

      {:ok, %{"id" => _id, "result" => _result} = payload} ->
        emit_message(
          on_message,
          :other_message,
          %{payload: payload, raw: payload_string},
          metadata_from_message(port, payload)
        )

        await_turn_completion(port, on_message, turn_timeout_ms, read_timeout_ms, "", session_id)

      {:ok, payload} ->
        emit_message(
          on_message,
          :other_message,
          %{payload: payload, raw: payload_string},
          metadata_from_message(port, payload)
        )

        await_turn_completion(port, on_message, turn_timeout_ms, read_timeout_ms, "", session_id)

      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "turn stream")

        emit_message(
          on_message,
          :malformed,
          %{payload: payload_string, raw: payload_string},
          metadata_from_message(port, %{raw: payload_string})
        )

        await_turn_completion(port, on_message, turn_timeout_ms, read_timeout_ms, "", session_id)
    end
  end

  defp maybe_emit_opencode_update_event(on_message, payload, payload_string, port, session_id) do
    kind = get_in(payload, ["params", "update", "sessionUpdate"])

    emit_message(
      on_message,
      :opencode_session_update,
      %{
        payload: payload,
        raw: payload_string,
        session_id: session_id,
        update_kind: kind
      },
      metadata_from_message(port, payload)
    )
  end

  defp normalize_mcp_servers(mcp_servers) when is_list(mcp_servers) do
    mcp_servers
    |> Enum.map(&stringify_keys/1)
    |> Enum.filter(&is_map/1)
  end

  defp normalize_mcp_servers(_mcp_servers), do: []

  defp stringify_keys(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
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

  defp await_response(port, request_id, timeout_ms) do
    with_timeout_response(port, request_id, timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for OpenCode response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{opencode_acp_pid: to_string(os_pid)}

      _ ->
        %{}
    end
  end

  defp metadata_from_message(port, payload) do
    usage =
      get_in(payload, ["result", "usage"]) ||
        get_in(payload, ["params", "update", "usage"]) ||
        get_in(payload, ["params", "update", "cost"])

    metadata = port_metadata(port)

    if is_map(usage), do: Map.put(metadata, :usage, usage), else: metadata
  end

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\\b(error|warn|warning|failed|fatal|panic|exception)\\b/i) do
        Logger.warning("OpenCode #{stream_label} output: #{text}")
      else
        Logger.debug("OpenCode #{stream_label} output: #{text}")
      end
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp default_on_message(_message), do: :ok

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end
end
