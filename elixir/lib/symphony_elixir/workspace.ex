defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @excluded_entries MapSet.new([".elixir_ls", "tmp"])

  @spec create_for_issue(map() | String.t() | nil) :: {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with {:ok, workspace} <- workspace_path_for_issue(safe_id),
           :ok <- validate_workspace_path(workspace),
           {:ok, created?} <- ensure_workspace(workspace),
           :ok <- maybe_run_after_create_hook(workspace, issue_context, created?) do
        {:ok, workspace}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace) do
    cond do
      File.dir?(workspace) ->
        clean_tmp_artifacts(workspace)
        {:ok, false}

      File.exists?(workspace) ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      true ->
        create_workspace(workspace)
    end
  end

  defp create_workspace(workspace) do
    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)
    {:ok, true}
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace) do
    case File.exists?(workspace) do
      true ->
        case validate_workspace_path(workspace) do
          :ok ->
            maybe_run_before_remove_hook(workspace)
            File.rm_rf(workspace)

          {:error, reason} ->
            {:error, reason, ""}
        end

      false ->
        File.rm_rf(workspace)
    end
  end

  @spec remove_issue_workspaces(term()) :: :ok
  def remove_issue_workspaces(identifier) when is_binary(identifier) do
    safe_id = safe_identifier(identifier)

    case workspace_path_for_issue(safe_id) do
      {:ok, workspace} -> remove(workspace)
      {:error, _reason} -> :ok
    end

    :ok
  end

  def remove_issue_workspaces(_identifier) do
    :ok
  end

  @spec total_usage_bytes(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def total_usage_bytes(workspace_root) when is_binary(workspace_root) do
    usage_for_path(Path.expand(workspace_root))
  end

  def total_usage_bytes(_workspace_root), do: {:error, :invalid_workspace_root}

  @spec root_usage_bytes() :: {:ok, non_neg_integer()} | {:error, term()}
  def root_usage_bytes do
    total_usage_bytes(Config.settings!().workspace.root)
  end

  @spec cleanup_completed_issue_workspaces([map()], keyword()) ::
          {:ok, %{kept: [String.t()], removed: [String.t()]}}
  def cleanup_completed_issue_workspaces(issues, opts \\ []) when is_list(issues) and is_list(opts) do
    keep_recent = keep_recent_option(opts)

    {kept, removed} =
      issues
      |> completed_issue_identifiers_sorted()
      |> Enum.split(keep_recent)

    Enum.each(removed, &remove_issue_workspaces/1)

    {:ok, %{kept: kept, removed: removed}}
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, keyword()) :: :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier, opts)
    hooks = Config.settings!().hooks

    case hooks.before_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "before_run")
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, keyword()) :: :ok
  def run_after_run_hook(workspace, issue_or_identifier, opts \\ []) when is_binary(workspace) do
    issue_context = issue_context(issue_or_identifier, opts)
    hooks = Config.settings!().hooks

    case hooks.after_run do
      nil ->
        :ok

      command ->
        run_hook(command, workspace, issue_context, "after_run")
        |> ignore_hook_failure()
    end
  end

  defp workspace_path_for_issue(safe_id) when is_binary(safe_id) do
    Config.settings!().workspace.root
    |> Path.join(safe_id)
    |> PathSafety.canonicalize()
  end

  defp safe_identifier(identifier) do
    String.replace(identifier || "issue", ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp keep_recent_option(opts) when is_list(opts) do
    case Keyword.get(opts, :keep_recent, Config.settings!().workspace.cleanup_keep_recent) do
      keep_recent when is_integer(keep_recent) and keep_recent >= 0 -> keep_recent
      _ -> 5
    end
  end

  defp completed_issue_identifiers_sorted(issues) do
    issues
    |> Enum.flat_map(fn issue ->
      case completed_issue_identifier(issue) do
        identifier when is_binary(identifier) -> [{identifier, completed_issue_sort_key(issue)}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {_identifier, sort_key} -> sort_key end, :desc)
    |> Enum.uniq_by(fn {identifier, _sort_key} -> identifier end)
    |> Enum.map(fn {identifier, _sort_key} -> identifier end)
  end

  defp completed_issue_identifier(%{identifier: identifier})
       when is_binary(identifier) and identifier != "" do
    identifier
  end

  defp completed_issue_identifier(%{"identifier" => identifier})
       when is_binary(identifier) and identifier != "" do
    identifier
  end

  defp completed_issue_identifier(_issue), do: nil

  defp completed_issue_sort_key(%{updated_at: %DateTime{} = updated_at}) do
    DateTime.to_unix(updated_at, :millisecond)
  end

  defp completed_issue_sort_key(%{"updated_at" => %DateTime{} = updated_at}) do
    DateTime.to_unix(updated_at, :millisecond)
  end

  defp completed_issue_sort_key(%{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :millisecond)
  end

  defp completed_issue_sort_key(%{"created_at" => %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :millisecond)
  end

  defp completed_issue_sort_key(_issue), do: 0

  defp usage_for_path(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        usage_for_directory(path)

      {:ok, %File.Stat{type: :regular, size: size}} when is_integer(size) and size > 0 ->
        {:ok, size}

      {:ok, %File.Stat{}} ->
        {:ok, 0}

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, {:workspace_usage_scan_failed, path, reason}}
    end
  end

  defp usage_for_directory(path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, 0}, fn entry, {:ok, acc} ->
          case usage_for_path(Path.join(path, entry)) do
            {:ok, size} -> {:cont, {:ok, acc + size}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, {:workspace_usage_scan_failed, path, reason}}
    end
  end

  defp clean_tmp_artifacts(workspace) do
    Enum.each(MapSet.to_list(@excluded_entries), fn entry ->
      File.rm_rf(Path.join(workspace, entry))
    end)
  end

  defp maybe_run_after_create_hook(workspace, issue_context, created?) do
    hooks = Config.settings!().hooks

    case created? do
      true ->
        case hooks.after_create do
          nil ->
            :ok

          command ->
            run_hook(command, workspace, issue_context, "after_create")
        end

      false ->
        :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace) do
    hooks = Config.settings!().hooks

    case File.dir?(workspace) do
      true ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            run_hook(
              command,
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace), trace_id: nil},
              "before_remove"
            )
            |> ignore_hook_failure()
        end

      false ->
        :ok
    end
  end

  defp ignore_hook_failure(:ok), do: :ok
  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name) do
    timeout_ms = Config.settings!().hooks.timeout_ms
    env = hook_env(issue_context)

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace}")

    task =
      Task.async(fn ->
        System.cmd("sh", ["-lc", command], cd: workspace, stderr_to_stdout: true, env: env)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      nil ->
        Task.shutdown(task, :brutal_kill)

        Logger.warning("Workspace hook timed out hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} timeout_ms=#{timeout_ms}")

        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    sanitized_output = sanitize_hook_output_for_log(output)

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output=#{inspect(sanitized_output)}")

    {:error, {:workspace_hook_failed, hook_name, status, output}}
  end

  defp sanitize_hook_output_for_log(output, max_bytes \\ 2_048) do
    binary_output = IO.iodata_to_binary(output)

    case byte_size(binary_output) <= max_bytes do
      true ->
        binary_output

      false ->
        binary_part(binary_output, 0, max_bytes) <> "... (truncated)"
    end
  end

  defp validate_workspace_path(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:workspace_equals_root, canonical_workspace, canonical_root}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          :ok

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:workspace_symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:workspace_outside_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:workspace_path_unreadable, path, reason}}
    end
  end

  defp issue_context(issue_or_identifier, opts \\ [])

  defp issue_context(%{id: issue_id, identifier: identifier} = issue, opts) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue",
      trace_id: Keyword.get(opts, :trace_id) || issue_trace_id(issue)
    }
  end

  defp issue_context(identifier, opts) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier,
      trace_id: Keyword.get(opts, :trace_id)
    }
  end

  defp issue_context(_identifier, opts) do
    %{
      issue_id: nil,
      issue_identifier: "issue",
      trace_id: Keyword.get(opts, :trace_id)
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier, trace_id: trace_id}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"} trace_id=#{trace_id || "n/a"}"
  end

  defp hook_env(issue_context) when is_map(issue_context) do
    []
    |> maybe_put_env("SYMPHONY_TRACE_ID", Map.get(issue_context, :trace_id))
  end

  defp issue_trace_id(%{trace_id: trace_id}) when is_binary(trace_id), do: trace_id
  defp issue_trace_id(_issue), do: nil

  defp maybe_put_env(env, _name, value) when value in [nil, ""], do: env
  defp maybe_put_env(env, name, value), do: [{name, value} | env]
end
