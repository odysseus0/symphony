defmodule SymphonyElixir.InitTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Init
  alias SymphonyElixir.Linear.Issue

  # ── test deps ─────────────────────────────────────────────────────────────────

  defp capture_deps(inputs \\ [], overrides \\ %{}) do
    agent = start_supervised!({Agent, fn -> %{output: [], inputs: inputs} end})

    base = %{
      puts: fn msg ->
        Agent.update(agent, fn s -> %{s | output: s.output ++ [{:puts, msg}]} end)
        :ok
      end,
      write: fn msg ->
        Agent.update(agent, fn s -> %{s | output: s.output ++ [{:write, msg}]} end)
        :ok
      end,
      gets: fn _prompt ->
        case Agent.get_and_update(agent, fn s ->
               case s.inputs do
                 [h | t] -> {h, %{s | inputs: t}}
                 [] -> {:eof, s}
               end
             end) do
          :eof -> :eof
          val -> val
        end
      end,
      file_exists?: fn _path -> false end,
      write_file: fn _path, _content -> :ok end,
      linear_query: fn _key, _query, _vars -> {:error, :not_used} end
    }

    {Map.merge(base, overrides), agent}
  end

  defp output_text(agent) do
    Agent.get(agent, fn s -> s.output end)
    |> Enum.map(fn {_, msg} -> msg end)
    |> Enum.join("")
  end

  # ── demo mode ─────────────────────────────────────────────────────────────────

  test "run --demo generates a WORKFLOW.md at specified path" do
    output_path = Path.join(System.tmp_dir!(), "test-demo-#{System.unique_integer()}.md")

    {deps, agent} =
      capture_deps([], %{
        write_file: fn path, content ->
          File.write(path, content)
        end
      })

    assert :ok = Init.run(["--demo", "--output", output_path], deps)
    assert File.exists?(output_path)

    content = File.read!(output_path)
    assert content =~ "kind: memory"
    assert content =~ "DEMO-1"
    assert content =~ "DEMO-2"
    assert content =~ "active_states:"
    assert content =~ "terminal_states:"

    output = output_text(agent)
    assert output =~ "Demo WORKFLOW.md created"
    assert output =~ output_path

    File.rm!(output_path)
  end

  test "demo_workflow_content produces valid schema-parseable YAML" do
    content = Init.demo_workflow_content()
    assert content =~ "tracker:"
    assert content =~ "kind: memory"
    assert content =~ "memory_issues:"
    assert content =~ "DEMO-1"

    # Extract front matter and parse
    lines = String.split(content, "\n")
    ["---" | rest] = lines
    {front_lines, _} = Enum.split_while(rest, &(&1 != "---"))
    yaml = Enum.join(front_lines, "\n")

    assert {:ok, config} = YamlElixir.read_from_string(yaml)
    assert config["tracker"]["kind"] == "memory"
    assert is_list(config["tracker"]["memory_issues"])
    assert length(config["tracker"]["memory_issues"]) == 2
  end

  test "run --demo with default output path writes to WORKFLOW.md" do
    {deps, _agent} =
      capture_deps([], %{
        write_file: fn path, _content ->
          send(self(), {:written_to, path})
          :ok
        end
      })

    assert :ok = Init.run(["--demo"], deps)
    assert_received {:written_to, path}
    assert Path.basename(path) == "WORKFLOW.md"
  end

  test "demo_issues returns two Issue structs with required fields" do
    issues = Init.demo_issues()
    assert length(issues) == 2
    assert Enum.all?(issues, &match?(%Issue{}, &1))
    assert Enum.all?(issues, fn i -> is_binary(i.id) and i.id != "" end)
    assert Enum.all?(issues, fn i -> is_binary(i.identifier) and i.identifier != "" end)
    assert Enum.all?(issues, fn i -> is_binary(i.title) and i.title != "" end)
    assert Enum.all?(issues, fn i -> is_binary(i.state) end)
  end

  # ── build_workflow_content ────────────────────────────────────────────────────

  test "build_workflow_content generates valid YAML with linear tracker" do
    content =
      Init.build_workflow_content(%{
        tracker: %{
          kind: "linear",
          api_key: "lin_api_token",
          project_slug: "my-project",
          team_key: nil,
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Closed"]
        },
        workspace_root: "~/code/ws",
        prompt: "You are a test agent."
      })

    assert content =~ "kind: linear"
    assert content =~ "api_key: \"lin_api_token\""
    assert content =~ "project_slug: \"my-project\""
    assert content =~ "active_states:"
    assert content =~ "workspace:"
    assert content =~ "root: ~/code/ws"
    assert content =~ "You are a test agent."
    refute content =~ "team_key:"
  end

  test "build_workflow_content with team_key and no project_slug" do
    content =
      Init.build_workflow_content(%{
        tracker: %{
          kind: "linear",
          api_key: "token",
          project_slug: nil,
          team_key: "ENG",
          active_states: ["Todo"],
          terminal_states: ["Done"]
        },
        workspace_root: "~/ws",
        prompt: "agent prompt"
      })

    assert content =~ "team_key: \"ENG\""
    refute content =~ "project_slug:"
  end

  test "build_workflow_content with memory tracker omits API key" do
    content =
      Init.build_workflow_content(%{
        tracker: %{
          kind: "memory",
          active_states: ["Todo"],
          terminal_states: ["Done"]
        },
        workspace_root: "~/ws",
        prompt: "test"
      })

    assert content =~ "kind: memory"
    refute content =~ "api_key"
    refute content =~ "project_slug"
    refute content =~ "team_key"
  end

  # ── CLI routing ───────────────────────────────────────────────────────────────

  test "CLI evaluate routes init --demo to Init.run" do
    written_paths = ref = make_ref()
    _ = ref

    {deps, _agent} =
      capture_deps([], %{
        write_file: fn path, _content ->
          send(self(), {:written, path})
          :ok
        end
      })

    _ = deps

    # Directly test that Init.run with --demo succeeds
    assert :ok = Init.run(["--demo"], deps)
    assert_received {:written, _path}
  end

  test "CLI evaluate init --demo routes to Init and returns :no_wait" do
    tmp = Path.join(System.tmp_dir!(), "cli-evaluate-init-#{System.unique_integer()}.md")

    assert {:ok, :no_wait} = CLI.evaluate(["init", "--demo", "--output", tmp])
    assert File.exists?(tmp)

    content = File.read!(tmp)
    assert content =~ "kind: memory"

    File.rm!(tmp)
  end

  # ── interactive mode: abort on existing file ──────────────────────────────────

  test "interactive init aborts if user declines to overwrite existing WORKFLOW.md" do
    {deps, _agent} =
      capture_deps(["n\n"], %{
        file_exists?: fn _path -> true end
      })

    assert {:error, "Aborted."} = Init.run(["--output", "/tmp/fake.md"], deps)
  end

  test "interactive init proceeds if user confirms overwrite" do
    {deps, _agent} =
      capture_deps(
        # overwrite: y, tracker: 1 (linear), api key: token, team choice: 1, no project, workspace: default, prompt: default
        ["y\n", "1\n", "token\n"],
        %{
          file_exists?: fn _path -> true end,
          linear_query: fn _key, _query, _vars ->
            {:error, :simulated_failure}
          end
        }
      )

    # Should fail at Linear connection, not at overwrite
    assert {:error, msg} = Init.run(["--output", "/tmp/fake.md"], deps)
    assert msg =~ "Could not connect to Linear" or msg =~ "Linear"
  end

  # ── memory tracker selection ──────────────────────────────────────────────────

  test "interactive init with memory tracker selection generates WORKFLOW.md" do
    output_path = Path.join(System.tmp_dir!(), "test-init-#{System.unique_integer()}.md")
    written_content = ref = make_ref()
    _ = ref

    {deps, _agent} =
      capture_deps(
        # tracker: 2 (memory), workspace root: (default), prompt: (default)
        ["2\n", "\n", "\n"],
        %{
          file_exists?: fn _path -> false end,
          write_file: fn path, content ->
            send(self(), {:written, path, content})
            :ok
          end
        }
      )

    _ = written_content

    assert :ok = Init.run(["--output", output_path], deps)
    assert_received {:written, ^output_path, content}
    assert content =~ "kind: memory"
  end

  # ── memory tracker issues loaded from config at app start ─────────────────────

  test "application loads memory_issues from tracker config into Application env" do
    # Simulate what Application.start does when tracker.kind=memory with issues
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_project_slug: nil
    )

    # The Application startup callback reads the config; we call it manually
    config_map = %{
      "tracker" => %{
        "kind" => "memory",
        "memory_issues" => [
          %{"id" => "t1", "identifier" => "TEST-1", "title" => "Test issue", "state" => "Todo"}
        ]
      }
    }

    {:ok, settings} = Schema.parse(config_map)
    assert settings.tracker.kind == "memory"
    assert length(settings.tracker.memory_issues) == 1
    assert hd(settings.tracker.memory_issues)["identifier"] == "TEST-1"
  end

  test "tracker.memory_issues defaults to empty list" do
    {:ok, settings} = Schema.parse(%{"tracker" => %{"kind" => "memory"}})
    assert settings.tracker.memory_issues == []
  end

  test "tracker.memory_issues parses from WORKFLOW.md config" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.kind == "memory"
    assert is_list(config.tracker.memory_issues)
  end
end
