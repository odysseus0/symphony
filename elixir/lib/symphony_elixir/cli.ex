defmodule SymphonyElixir.CLI do
  @moduledoc """
  Escript entrypoint for running Symphony with an explicit WORKFLOW.md path.
  """

  alias SymphonyElixir.DynamicTools.MCPServer
  alias SymphonyElixir.LogFile

  @acknowledgement_switch :i_understand_that_this_will_be_running_without_the_usual_guardrails
  @switches [{@acknowledgement_switch, :boolean}, logs_root: :string, port: :integer]
  @default_consent_file "~/.config/symphony/.consented"

  @type ensure_started_result :: {:ok, [atom()]} | {:error, term()}
  @type deps :: %{
          file_regular?: (String.t() -> boolean()),
          set_workflow_file_path: (String.t() -> :ok | {:error, term()}),
          set_logs_root: (String.t() -> :ok | {:error, term()}),
          set_server_port_override: (non_neg_integer() | nil -> :ok | {:error, term()}),
          run_dynamic_tools_mcp: ([String.t()] -> :ok | {:error, String.t()}),
          ensure_all_started: (-> ensure_started_result()),
          consent_file_path: String.t(),
          write_consent: (String.t() -> :ok),
          ask_for_consent: (-> boolean())
        }

  @spec main([String.t()]) :: no_return()
  def main(["dynamic-tools-mcp" | rest]) do
    MCPServer.main(rest)
  end

  def main(args) do
    case evaluate(args) do
      :ok ->
        wait_for_shutdown()

      {:ok, :no_wait} ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec evaluate([String.t()], deps()) :: :ok | {:ok, :no_wait} | {:error, String.t()}
  def evaluate(args, deps \\ runtime_deps())

  def evaluate(["dynamic-tools-mcp" | rest], deps) do
    deps.run_dynamic_tools_mcp.(rest)
  end

  def evaluate(["on" | rest], deps) do
    case OptionParser.parse(rest, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_consent(opts, deps),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_consent(opts, deps),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  def evaluate(["off" | _rest], _deps), do: {:ok, :no_wait}
  def evaluate(["status" | _rest], _deps), do: {:ok, :no_wait}
  def evaluate(["init" | _rest], _deps), do: {:ok, :no_wait}
  def evaluate(["doctor" | _rest], _deps), do: {:ok, :no_wait}
  def evaluate(["logs" | _rest], _deps) do
    IO.puts("symphony logs is handled by the bin/symphony shell wrapper, not the escript directly.")
    {:ok, :no_wait}
  end

  def evaluate(["intervene" | _rest], _deps) do
    IO.puts("symphony intervene is handled by the bin/symphony shell wrapper, not the escript directly.")
    {:ok, :no_wait}
  end

  # Backward-compatible: old-style invocation with guardrail flag (CI/scripts)
  def evaluate(args, deps) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(Path.expand("WORKFLOW.md"), deps)
        end

      {opts, [workflow_path], []} ->
        with :ok <- require_guardrails_acknowledgement(opts),
             :ok <- maybe_set_logs_root(opts, deps),
             :ok <- maybe_set_server_port(opts, deps) do
          run(workflow_path, deps)
        end

      _ ->
        {:error, usage_message()}
    end
  end

  @spec run(String.t(), deps()) :: :ok | {:error, String.t()}
  def run(workflow_path, deps) do
    expanded_path = Path.expand(workflow_path)

    if deps.file_regular?.(expanded_path) do
      :ok = deps.set_workflow_file_path.(expanded_path)

      case deps.ensure_all_started.() do
        {:ok, _started_apps} ->
          :ok

        {:error, reason} ->
          {:error, "Failed to start Symphony with workflow #{expanded_path}: #{inspect(reason)}"}
      end
    else
      {:error, "Workflow file not found: #{expanded_path}"}
    end
  end

  @spec usage_message() :: String.t()
  defp usage_message do
    """
    Usage:
      symphony on [path-to-WORKFLOW.md] [--logs-root <path>] [--port <port>]
      symphony off
      symphony status
      symphony init
      symphony doctor
      symphony logs [--issue <identifier>] [--full] [--port <port>]
      symphony intervene <issue-identifier> <directive> [--port <port>]
      symphony dynamic-tools-mcp [--linear-api-key <token>] [--linear-endpoint <url>]

    Legacy (CI/scripts):
      symphony [--logs-root <path>] [--port <port>] [path-to-WORKFLOW.md] --i-understand-that-this-will-be-running-without-the-usual-guardrails
    """
    |> String.trim()
  end

  @spec runtime_deps() :: deps()
  defp runtime_deps do
    %{
      file_regular?: &File.regular?/1,
      set_workflow_file_path: &SymphonyElixir.Workflow.set_workflow_file_path/1,
      set_logs_root: &set_logs_root/1,
      set_server_port_override: &set_server_port_override/1,
      run_dynamic_tools_mcp: &MCPServer.run_cli/1,
      ensure_all_started: fn -> Application.ensure_all_started(:symphony_elixir) end,
      consent_file_path: Path.expand(@default_consent_file),
      write_consent: &write_consent/1,
      ask_for_consent: &ask_for_consent/0
    }
  end

  defp require_consent(opts, deps) do
    cond do
      Keyword.get(opts, @acknowledgement_switch, false) ->
        :ok

      deps.file_regular?.(deps.consent_file_path) ->
        :ok

      deps.ask_for_consent.() ->
        deps.write_consent.(deps.consent_file_path)

      true ->
        {:error, acknowledgement_banner()}
    end
  end

  defp require_guardrails_acknowledgement(opts) do
    if Keyword.get(opts, @acknowledgement_switch, false) do
      :ok
    else
      {:error, acknowledgement_banner()}
    end
  end

  defp maybe_set_logs_root(opts, deps) do
    case Keyword.get_values(opts, :logs_root) do
      [] ->
        :ok

      values ->
        logs_root = values |> List.last() |> String.trim()

        if logs_root == "" do
          {:error, usage_message()}
        else
          :ok = deps.set_logs_root.(Path.expand(logs_root))
        end
    end
  end

  defp maybe_set_server_port(opts, deps) do
    case Keyword.get_values(opts, :port) do
      [] ->
        :ok

      values ->
        port = List.last(values)

        if is_integer(port) and port >= 0 do
          :ok = deps.set_server_port_override.(port)
        else
          {:error, usage_message()}
        end
    end
  end

  @spec acknowledgement_banner() :: String.t()
  defp acknowledgement_banner do
    lines = [
      "This Symphony implementation is a low key engineering preview.",
      "Codex will run without any guardrails.",
      "SymphonyElixir is not a supported product and is presented as-is.",
      "To proceed, start with `--i-understand-that-this-will-be-running-without-the-usual-guardrails` CLI argument"
    ]

    width = Enum.max(Enum.map(lines, &String.length/1))
    border = String.duplicate("─", width + 2)
    top = "╭" <> border <> "╮"
    bottom = "╰" <> border <> "╯"
    spacer = "│ " <> String.duplicate(" ", width) <> " │"

    content =
      [
        top,
        spacer
        | Enum.map(lines, fn line ->
            "│ " <> String.pad_trailing(line, width) <> " │"
          end)
      ] ++ [spacer, bottom]

    [
      IO.ANSI.red(),
      IO.ANSI.bright(),
      Enum.join(content, "\n"),
      IO.ANSI.reset()
    ]
    |> IO.iodata_to_binary()
  end

  defp set_logs_root(logs_root) do
    Application.put_env(:symphony_elixir, :log_file, LogFile.default_log_file(logs_root))
    :ok
  end

  defp write_consent(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, "")
    :ok
  end

  defp ask_for_consent do
    IO.puts(acknowledgement_banner())
    IO.write("\nType YES to proceed: ")

    case IO.gets("") do
      line when is_binary(line) -> String.trim(line) == "YES"
      _ -> false
    end
  end

  defp set_server_port_override(port) when is_integer(port) and port >= 0 do
    Application.put_env(:symphony_elixir, :server_port_override, port)
    :ok
  end

  @spec wait_for_shutdown() :: no_return()
  defp wait_for_shutdown do
    case Process.whereis(SymphonyElixir.Supervisor) do
      nil ->
        IO.puts(:stderr, "Symphony supervisor is not running")
        System.halt(1)

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            case reason do
              :normal -> System.halt(0)
              _ -> System.halt(1)
            end
        end
    end
  end
end
