defmodule SymphonyElixir.Init do
  @moduledoc """
  Interactive `symphony init` wizard and `--demo` mode.

  Standard mode walks the user through:
    1. Tracker selection (Linear or memory)
    2. API key entry + Linear project discovery
    3. Workspace root + agent settings
    4. WORKFLOW.md generation and validation

  Demo mode (`--demo`) generates a ready-to-run WORKFLOW.md backed by the
  in-memory tracker with pre-seeded sample issues — no external accounts needed.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  @linear_endpoint "https://api.linear.app/graphql"

  @type io_deps :: %{
          puts: (String.t() -> :ok),
          write: (String.t() -> :ok),
          gets: (String.t() -> String.t() | :eof),
          file_exists?: (String.t() -> boolean()),
          write_file: (String.t(), String.t() -> :ok | {:error, term()}),
          linear_query: (String.t(), String.t(), map() -> {:ok, map()} | {:error, term()})
        }

  # ── public API ────────────────────────────────────────────────────────────────

  @spec run([String.t()]) :: :ok | {:error, String.t()}
  def run(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: [demo: :boolean, output: :string]) do
      {opts, [], []} ->
        output_path = Keyword.get(opts, :output, "WORKFLOW.md")

        if Keyword.get(opts, :demo, false) do
          run_demo(output_path, deps)
        else
          run_interactive(output_path, deps)
        end

      _ ->
        {:error, "Usage: symphony init [--demo] [--output <path>]"}
    end
  end

  # ── demo mode ────────────────────────────────────────────────────────────────

  @spec run_demo(String.t(), io_deps()) :: :ok | {:error, String.t()}
  def run_demo(output_path \\ "WORKFLOW.md", deps \\ runtime_deps()) do
    expanded = Path.expand(output_path)

    with :ok <- check_existing_file(expanded, deps) do
      content = demo_workflow_content()

      case write_workflow(expanded, content, deps) do
        :ok ->
          deps.puts.("")
          deps.puts.("✓ Demo WORKFLOW.md created at #{expanded}")
          deps.puts.("")
          deps.puts.("  2 sample issues pre-loaded (DEMO-1, DEMO-2).")
          deps.puts.("  No API keys needed — uses the in-memory tracker.")
          deps.puts.("")
          project_dir = Path.dirname(expanded)
          deps.puts.("  Run: symphony on #{project_dir}")
          deps.puts.("")
          :ok

        {:error, reason} ->
          {:error, "Could not write #{expanded}: #{inspect(reason)}"}
      end
    end
  end

  @doc false
  @spec demo_workflow_content() :: String.t()
  def demo_workflow_content do
    """
    ---
    tracker:
      kind: memory
      active_states: ["Todo", "In Progress"]
      terminal_states: ["Done", "Cancelled"]
      memory_issues:
        - id: "demo-1"
          identifier: "DEMO-1"
          title: "Add a hello world HTTP endpoint"
          description: |
            Create a simple GET /hello endpoint that returns {"message": "Hello, World!"}.
            Write a unit test that verifies the response status and body.
          state: "Todo"
          priority: 2
        - id: "demo-2"
          identifier: "DEMO-2"
          title: "Add input validation to the user creation endpoint"
          description: |
            The POST /users endpoint should validate that email is non-empty and
            properly formatted. Return HTTP 422 with {"error": "invalid_email"} on
            invalid input. Add a test for both valid and invalid cases.
          state: "Todo"
          priority: 3
    polling:
      interval_ms: 5000
    workspace:
      root: ~/code/symphony-demo-workspaces
    agent:
      max_concurrent_agents: 1
      max_turns: 20
      max_retry_backoff_ms: 300000
    codex:
      command: codex app-server
      approval_policy:
        reject:
          sandbox_approval: true
          rules: true
          mcp_elicitations: true
      thread_sandbox: workspace-write
    hooks:
      timeout_ms: 60000
    observability:
      dashboard_enabled: true
      refresh_ms: 1000
      render_interval_ms: 16
    ---
    You are a helpful coding agent. Work on the assigned issue carefully, write tests, and commit your changes.
    """
  end

  # ── interactive mode ──────────────────────────────────────────────────────────

  @spec run_interactive(String.t(), io_deps()) :: :ok | {:error, String.t()}
  defp run_interactive(output_path, deps) do
    deps.puts.("")
    deps.puts.("Symphony Init — interactive setup wizard")
    deps.puts.("════════════════════════════════════════")
    deps.puts.("")

    expanded_path = Path.expand(output_path)

    with :ok <- check_existing_file(expanded_path, deps),
         {:ok, tracker_kind} <- ask_tracker_kind(deps),
         {:ok, tracker_config} <- build_tracker_config(tracker_kind, deps),
         {:ok, workspace_root} <- ask_workspace_root(deps),
         {:ok, prompt} <- ask_prompt(deps) do
      content =
        build_workflow_content(%{
          tracker: tracker_config,
          workspace_root: workspace_root,
          prompt: prompt
        })

      case write_workflow(expanded_path, content, deps) do
        :ok ->
          case Schema.parse(parse_front_matter(content)) do
            {:ok, _settings} ->
              deps.puts.("")
              deps.puts.("✓ WORKFLOW.md created at #{expanded_path}")
              deps.puts.("")
              project_dir = Path.dirname(expanded_path)
              deps.puts.("  Run: symphony on #{project_dir}")
              deps.puts.("")
              :ok

            {:error, {:invalid_workflow_config, msg}} ->
              {:error, "Generated WORKFLOW.md is invalid: #{msg}"}
          end

        {:error, reason} ->
          {:error, "Could not write #{expanded_path}: #{inspect(reason)}"}
      end
    end
  end

  defp check_existing_file(output_path, deps) do
    if deps.file_exists?.(output_path) do
      deps.write.("#{output_path} already exists. Overwrite? [y/N] ")

      case deps.gets.("") do
        line when is_binary(line) ->
          if String.trim(line) in ["y", "Y", "yes", "Yes"] do
            :ok
          else
            {:error, "Aborted."}
          end

        _ ->
          {:error, "Aborted."}
      end
    else
      :ok
    end
  end

  defp ask_tracker_kind(deps) do
    deps.puts.("Tracker type:")
    deps.puts.("  1) Linear  (issue tracking via Linear API)")
    deps.puts.("  2) Memory  (local only, no API key needed)")
    deps.puts.("")
    deps.write.("Select [1/2, default 1]: ")

    case deps.gets.("") do
      line when is_binary(line) ->
        case String.trim(line) do
          "" -> {:ok, "linear"}
          "1" -> {:ok, "linear"}
          "2" -> {:ok, "memory"}
          other -> {:error, "Unknown tracker type: #{other}"}
        end

      _ ->
        {:error, "Aborted."}
    end
  end

  defp build_tracker_config("memory", _deps) do
    {:ok,
     %{
       kind: "memory",
       active_states: ["Todo", "In Progress"],
       terminal_states: ["Done", "Cancelled"]
     }}
  end

  defp build_tracker_config("linear", deps) do
    with {:ok, api_key, typed_key} <- ask_linear_api_key(deps),
         {:ok, project_slug, team_key} <- discover_linear_project(api_key, deps) do
      if typed_key do
        deps.puts.("")
        deps.puts.("  Your API key was used to connect to Linear but will NOT be written to WORKFLOW.md.")
        deps.puts.("  Set it permanently in your shell profile (replace <key> with the token you just entered):")
        deps.puts.("    export LINEAR_API_KEY=<your-linear-api-key>")
        deps.puts.("")
      end

      {:ok,
       %{
         kind: "linear",
         project_slug: project_slug,
         team_key: team_key,
         active_states: ["Todo", "In Progress"],
         terminal_states: ["Done", "Cancelled", "Cancelled", "Duplicate", "Closed"]
       }}
    end
  end

  # Returns {:ok, resolved_key, typed?} where typed? is true when the user entered
  # a key explicitly (vs pressing Enter to reuse the env var).  The key itself is
  # never written to WORKFLOW.md — the caller uses it only for the connection test.
  defp ask_linear_api_key(deps) do
    existing = System.get_env("LINEAR_API_KEY")

    prompt =
      if existing do
        "Linear API key [press Enter to use LINEAR_API_KEY env var]: "
      else
        "Linear API key: "
      end

    deps.write.(prompt)

    case deps.gets.("") do
      line when is_binary(line) ->
        trimmed = String.trim(line)

        cond do
          trimmed != "" -> {:ok, trimmed, true}
          existing != nil -> {:ok, existing, false}
          true -> {:error, "A Linear API key is required."}
        end

      _ ->
        {:error, "Aborted."}
    end
  end

  defp discover_linear_project(api_key, deps) do
    deps.puts.("")
    deps.puts.("Connecting to Linear...")

    teams_query = """
    query { teams { nodes { id key name } } }
    """

    case deps.linear_query.(api_key, teams_query, %{}) do
      {:ok, %{"data" => %{"teams" => %{"nodes" => teams}}}} when is_list(teams) ->
        select_linear_project(api_key, teams, deps)

      {:ok, %{"errors" => errors}} ->
        msg = errors |> List.first() |> Map.get("message", "unknown error")
        {:error, "Linear API error: #{msg}"}

      {:error, reason} ->
        {:error, "Could not connect to Linear: #{inspect(reason)}"}
    end
  end

  defp select_linear_project(api_key, teams, deps) do
    deps.puts.("")
    deps.puts.("Found #{length(teams)} team(s):")

    teams
    |> Enum.with_index(1)
    |> Enum.each(fn {team, i} ->
      deps.puts.("  #{i}) #{team["name"]} (#{team["key"]})")
    end)

    deps.puts.("")
    deps.write.("Select team [1..#{length(teams)}, default 1]: ")

    team =
      case deps.gets.("") do
        line when is_binary(line) ->
          idx = line |> String.trim() |> Integer.parse() |> elem_or(0)
          Enum.at(teams, max(idx, 1) - 1) || List.first(teams)

        _ ->
          List.first(teams)
      end

    if team do
      discover_projects_for_team(api_key, team, deps)
    else
      {:error, "No teams found in your Linear workspace."}
    end
  end

  defp discover_projects_for_team(api_key, team, deps) do
    projects_query = """
    query($teamId: String!) {
      team(id: $teamId) {
        projects { nodes { id name slugId } }
      }
    }
    """

    case deps.linear_query.(api_key, projects_query, %{"teamId" => team["id"]}) do
      {:ok, %{"data" => %{"team" => %{"projects" => %{"nodes" => projects}}}}} ->
        ask_project_selection(projects, team, deps)

      _ ->
        deps.puts.("Could not list projects, using team key only.")
        {:ok, nil, team["key"]}
    end
  end

  defp ask_project_selection([], team, _deps) do
    {:ok, nil, team["key"]}
  end

  defp ask_project_selection(projects, team, deps) do
    deps.puts.("")
    deps.puts.("Found #{length(projects)} project(s) in #{team["name"]}:")

    projects
    |> Enum.with_index(1)
    |> Enum.each(fn {proj, i} ->
      deps.puts.("  #{i}) #{proj["name"]} (#{proj["slugId"]})")
    end)

    deps.puts.("  #{length(projects) + 1}) Use team key only (no project filter)")
    deps.puts.("")
    deps.write.("Select project [1..#{length(projects) + 1}, default 1]: ")

    choice =
      case deps.gets.("") do
        line when is_binary(line) ->
          line |> String.trim() |> Integer.parse() |> elem_or(1)

        _ ->
          1
      end

    if choice > length(projects) do
      {:ok, nil, team["key"]}
    else
      proj = Enum.at(projects, choice - 1) || List.first(projects)
      {:ok, proj["slugId"], nil}
    end
  end

  defp ask_workspace_root(deps) do
    default = "~/code/symphony-workspaces"
    deps.write.("Workspace root [#{default}]: ")

    case deps.gets.("") do
      line when is_binary(line) ->
        trimmed = String.trim(line)
        {:ok, if(trimmed == "", do: default, else: trimmed)}

      _ ->
        {:ok, default}
    end
  end

  defp ask_prompt(deps) do
    default = "You are a helpful coding agent. Work on the assigned issue carefully, write tests, and commit your changes."
    deps.puts.("")
    deps.puts.("Agent prompt (leave blank for default):")
    deps.write.("> ")

    case deps.gets.("") do
      line when is_binary(line) ->
        trimmed = String.trim(line)
        {:ok, if(trimmed == "", do: default, else: trimmed)}

      _ ->
        {:ok, default}
    end
  end

  # ── WORKFLOW.md generation ────────────────────────────────────────────────────

  @spec build_workflow_content(map()) :: String.t()
  def build_workflow_content(%{tracker: tracker, workspace_root: workspace_root, prompt: prompt}) do
    tracker_section = tracker_yaml(tracker)

    """
    ---
    #{tracker_section}
    polling:
      interval_ms: 5000
    workspace:
      root: #{workspace_root}
    agent:
      max_concurrent_agents: 3
      max_turns: 20
      max_retry_backoff_ms: 300000
    codex:
      command: codex app-server
      approval_policy:
        reject:
          sandbox_approval: true
          rules: true
          mcp_elicitations: true
      thread_sandbox: workspace-write
    hooks:
      timeout_ms: 60000
    observability:
      dashboard_enabled: true
      refresh_ms: 1000
      render_interval_ms: 16
    ---
    #{prompt}
    """
  end

  defp tracker_yaml(%{kind: "memory"} = tracker) do
    active = tracker |> Map.get(:active_states, ["Todo", "In Progress"]) |> yaml_string_list()
    terminal = tracker |> Map.get(:terminal_states, ["Done", "Cancelled"]) |> yaml_string_list()

    Enum.join(
      [
        "tracker:",
        "  kind: memory",
        "  active_states: #{active}",
        "  terminal_states: #{terminal}"
      ],
      "\n"
    )
  end

  defp tracker_yaml(%{kind: "linear"} = tracker) do
    active = tracker |> Map.get(:active_states, ["Todo", "In Progress"]) |> yaml_string_list()

    terminal =
      tracker
      |> Map.get(:terminal_states, ["Done", "Cancelled", "Duplicate", "Closed"])
      |> yaml_string_list()

    lines =
      ["tracker:", "  kind: linear"] ++
        (if tracker[:api_key], do: ["  api_key: \"#{tracker[:api_key]}\""], else: []) ++
        (if tracker[:project_slug], do: ["  project_slug: \"#{tracker[:project_slug]}\""], else: []) ++
        (if tracker[:team_key], do: ["  team_key: \"#{tracker[:team_key]}\""], else: []) ++
        [
          "  active_states: #{active}",
          "  terminal_states: #{terminal}"
        ]

    Enum.join(lines, "\n")
  end

  defp yaml_string_list(items) do
    "[" <> Enum.map_join(items, ", ", &~s("#{&1}")) <> "]"
  end

  defp write_workflow(output_path, content, deps) do
    expanded = Path.expand(output_path)

    case expanded |> Path.dirname() |> File.mkdir_p() do
      :ok -> deps.write_file.(expanded, content)
      {:error, reason} -> {:error, "Cannot create directory #{Path.dirname(expanded)}: #{:file.format_error(reason)}"}
    end
  end

  # Parse just the front-matter map from a WORKFLOW.md string (for validation)
  defp parse_front_matter(content) do
    lines = String.split(content, ~r/\R/, trim: false)

    front =
      case lines do
        ["---" | tail] ->
          {front_lines, _} = Enum.split_while(tail, &(&1 != "---"))
          Enum.join(front_lines, "\n")

        _ ->
          ""
      end

    case YamlElixir.read_from_string(front) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  # ── Linear API helper ─────────────────────────────────────────────────────────

  defp linear_query(api_key, query, variables) do
    case Req.post(@linear_endpoint,
           headers: [
             {"Authorization", api_key},
             {"Content-Type", "application/json"}
           ],
           json: %{"query" => query, "variables" => variables},
           connect_options: [timeout: 10_000]
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── runtime deps ─────────────────────────────────────────────────────────────

  @spec runtime_deps() :: io_deps()
  def runtime_deps do
    %{
      puts: fn msg -> IO.puts(msg) end,
      write: fn msg -> IO.write(msg) end,
      gets: fn _prompt -> IO.gets("") end,
      file_exists?: &File.exists?/1,
      write_file: &File.write/2,
      linear_query: &linear_query/3
    }
  end

  # ── helpers ───────────────────────────────────────────────────────────────────

  defp elem_or({n, _}, _default) when is_integer(n), do: n
  defp elem_or(:error, default), do: default

  # Allow tests to pre-seed memory issues directly via Issue structs.
  # This is used in tests and demo mode when issues are defined in WORKFLOW.md.
  @doc false
  @spec demo_issues() :: [Issue.t()]
  def demo_issues do
    [
      %Issue{
        id: "demo-1",
        identifier: "DEMO-1",
        title: "Add a hello world HTTP endpoint",
        description:
          "Create a simple GET /hello endpoint that returns {\"message\": \"Hello, World!\"}. Write a unit test.",
        state: "Todo",
        priority: 2,
        url: "",
        labels: []
      },
      %Issue{
        id: "demo-2",
        identifier: "DEMO-2",
        title: "Add input validation to the user creation endpoint",
        description:
          "The POST /users endpoint should validate that email is properly formatted. Return HTTP 422 on invalid input.",
        state: "Todo",
        priority: 3,
        url: "",
        labels: []
      }
    ]
  end
end
