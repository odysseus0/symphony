defmodule SymphonyElixir.Doctor do
  @moduledoc """
  Diagnostic checks for a Symphony installation.

  Run via `symphony doctor`. Checks each precondition independently,
  prints ✓/✗ + a fix suggestion for each failure, and exits non-zero
  if any check fails.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Workflow

  @linear_endpoint "https://api.linear.app/graphql"

  @type check_result :: {:ok, String.t()} | {:error, String.t(), String.t()}
  @type deps :: %{
          puts: (String.t() -> :ok),
          workflow_file_path: (-> String.t()),
          load_config: (-> {:ok, term()} | {:error, term()}),
          resolve_api_key: (-> String.t() | nil),
          test_linear_connection: (String.t() -> :ok | {:error, term()}),
          find_executable: (String.t() -> String.t() | nil),
          test_git_remote: (String.t() -> :ok | {:error, String.t()}),
          check_dir_writable: (String.t() -> :ok | {:error, String.t()})
        }

  @spec run(deps()) :: :ok | {:error, String.t()}
  def run(deps \\ runtime_deps()) do
    workflow_path = deps.workflow_file_path.()

    checks = [
      check_workflow_file(workflow_path, deps),
      check_api_key(deps),
      check_agent_backend(deps),
      check_git_remote(deps),
      check_workspace_root(deps)
    ]

    any_fail = Enum.any?(checks, &match?({:error, _, _}, &1))

    deps.puts.("")
    deps.puts.("Symphony Doctor")
    deps.puts.("═══════════════")
    deps.puts.("")

    Enum.each(checks, fn
      {:ok, label} ->
        deps.puts.("  ✓  #{label}")

      {:error, label, fix} ->
        deps.puts.("  ✗  #{label}")
        deps.puts.("       Fix: #{fix}")
    end)

    deps.puts.("")

    if any_fail do
      {:error, "One or more checks failed."}
    else
      deps.puts.("All checks passed.")
      :ok
    end
  end

  # ── individual checks ────────────────────────────────────────────────────────

  defp check_workflow_file(path, deps) do
    label = "WORKFLOW.md valid (#{Path.basename(path)})"

    case deps.load_config.() do
      {:ok, _settings} ->
        {:ok, label}

      {:error, {:missing_workflow_file, p, _}} ->
        {:error, label, "Create WORKFLOW.md at #{p}  (run: symphony init)"}

      {:error, {:invalid_workflow_config, msg}} ->
        {:error, label, "Fix WORKFLOW.md: #{msg}"}

      {:error, reason} ->
        {:error, label, "Cannot load config: #{inspect(reason)}"}
    end
  end

  defp check_api_key(deps) do
    label = "API key valid"

    # Only linear tracker requires a remote API key check — other trackers
    # (memory, plane) either need no key or connect to a different endpoint.
    tracker_kind =
      case deps.load_config.() do
        {:ok, %{tracker: %{kind: kind}}} -> kind
        _ -> "linear"
      end

    if tracker_kind != "linear" do
      {:ok, "#{label} (#{tracker_kind} tracker, skipped)"}
    else
      case deps.resolve_api_key.() do
        nil ->
          {:error, label, "Set LINEAR_API_KEY env var or add api_key to WORKFLOW.md"}

        key ->
          case deps.test_linear_connection.(key) do
            :ok ->
              {:ok, label}

            {:error, reason} ->
              {:error, label, "API key rejected: #{inspect(reason)}  — check key is correct"}
          end
      end
    end
  end

  defp check_agent_backend(deps) do
    label = "Agent backend executable"

    # Try to read the codex command from config; fall back to "codex"
    command =
      case deps.load_config.() do
        {:ok, settings} -> settings.codex.command |> String.split() |> List.first() || "codex"
        _ -> "codex"
      end

    case deps.find_executable.(command) do
      nil ->
        {:error, label, "#{command} not found in PATH — install Codex or set codex.command in WORKFLOW.md"}

      _path ->
        {:ok, "#{label} (#{command})"}
    end
  end

  defp check_git_remote(deps) do
    label = "Git remote reachable"

    case deps.load_config.() do
      {:ok, settings} ->
        remote = get_in(settings, [Access.key(:hooks), Access.key(:after_create)])

        git_url =
          if is_binary(remote) do
            # Find the git clone URL by scanning for a token that looks like a
            # remote URL (contains "://", starts with "git@", or is "ssh://" etc.).
            # This is more robust than positional parsing which breaks on flags.
            remote
            |> String.split()
            |> Enum.drop_while(&(&1 != "clone"))
            |> Enum.drop(1)
            |> Enum.find(fn token ->
              String.contains?(token, "://") or
                String.starts_with?(token, "git@") or
                String.starts_with?(token, "ssh://") or
                String.starts_with?(token, "https://") or
                String.starts_with?(token, "http://")
            end)
          end

        case git_url do
          nil ->
            # No clone URL in hooks — skip this check
            {:ok, "#{label} (no after_create hook, skipped)"}

          url ->
            case deps.test_git_remote.(url) do
              :ok -> {:ok, "#{label} (#{url})"}
              {:error, msg} -> {:error, label, "Cannot reach #{url}: #{msg}  — check network/SSH keys"}
            end
        end

      _ ->
        {:ok, "#{label} (config unavailable, skipped)"}
    end
  end

  defp check_workspace_root(deps) do
    label = "Workspace root writable"

    case deps.load_config.() do
      {:ok, settings} ->
        root = Path.expand(settings.workspace.root)

        case deps.check_dir_writable.(root) do
          :ok -> {:ok, "#{label} (#{root})"}
          {:error, msg} -> {:error, label, "#{root} is not writable: #{msg}  — fix permissions or update workspace.root"}
        end

      _ ->
        {:ok, "#{label} (config unavailable, skipped)"}
    end
  end

  # ── runtime deps ─────────────────────────────────────────────────────────────

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      puts: &IO.puts/1,
      workflow_file_path: &Workflow.workflow_file_path/0,
      load_config: fn ->
        case Config.settings() do
          {:ok, settings} -> {:ok, settings}
          {:error, reason} -> {:error, reason}
        end
      end,
      resolve_api_key: fn ->
        case Config.settings() do
          {:ok, %{tracker: %{api_key: key}}} when is_binary(key) and key != "" -> key
          _ -> nil
        end
      end,
      test_linear_connection: &test_linear_connection/1,
      find_executable: &System.find_executable/1,
      test_git_remote: &test_git_remote/1,
      check_dir_writable: &check_dir_writable/1
    }
  end

  # ── private helpers ───────────────────────────────────────────────────────────

  defp test_linear_connection(api_key) do
    case Req.post(@linear_endpoint,
           json: %{query: "{ viewer { id } }"},
           headers: [{"Authorization", api_key}],
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => _}}}}} ->
        :ok

      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        {:error, {:graphql_errors, errors}}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp test_git_remote(url) do
    case System.cmd("git", ["ls-remote", "--exit-code", "--heads", url],
           stderr_to_stdout: true,
           timeout: 10_000
         ) do
      {_, 0} -> :ok
      {output, _code} -> {:error, String.trim(output)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp check_dir_writable(path) do
    case File.mkdir_p(path) do
      :ok ->
        probe = Path.join(path, ".symphony_doctor_probe_#{:erlang.unique_integer()}")

        case File.write(probe, "") do
          :ok ->
            File.rm(probe)
            :ok

          {:error, reason} ->
            {:error, :file.format_error(reason)}
        end

      {:error, reason} ->
        {:error, "cannot create directory: #{:file.format_error(reason)}"}
    end
  end
end
