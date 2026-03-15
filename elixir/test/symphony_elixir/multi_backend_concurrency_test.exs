defmodule SymphonyElixir.MultiBackendConcurrencyTest do
  use SymphonyElixir.TestSupport

  @backends [:codex, :opencode, :claude]

  test "concurrent mixed backend runs stay isolated per issue" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-multi-backend-concurrency-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "codex app-server"
      )

      fixtures =
        Enum.map(@backends, fn backend ->
          workspace = Path.join(workspace_root, "BUB-87-#{String.upcase(to_string(backend))}")
          binary = Path.join(test_root, "fake-#{backend}")
          trace_file = Path.join(test_root, "trace-#{backend}.log")

          File.mkdir_p!(workspace)
          File.write!(binary, fake_backend_script(backend, trace_file))
          File.chmod!(binary, 0o755)

          issue = issue_fixture(backend)
          %{backend: backend, workspace: workspace, binary: binary, trace_file: trace_file, issue: issue}
        end)

      results =
        fixtures
        |> Task.async_stream(
          fn %{backend: backend, workspace: workspace, binary: binary, issue: issue} ->
            result = AppServer.run(workspace, "run backend #{backend}", issue, command: "#{binary} app-server")
            {backend, issue, result}
          end,
          max_concurrency: 3,
          timeout: 10_000,
          ordered: false
        )
        |> Enum.map(fn {:ok, value} -> value end)

      assert length(results) == 3

      Enum.each(results, fn {backend, issue, result} ->
        assert {:ok, %{session_id: session_id}} = result
        assert session_id == "thread-#{backend}-turn-#{backend}"

        fixture = Enum.find(fixtures, &(&1.backend == backend))
        trace = File.read!(fixture.trace_file)
        assert trace =~ ~s("title":"#{issue.identifier}: #{issue.title}")

        Enum.each(@backends -- [backend], fn other_backend ->
          other_issue = issue_fixture(other_backend)
          refute trace =~ other_issue.identifier
        end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "agent runner routes command by backend label mapping" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-multi-backend-routing-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      File.mkdir_p!(workspace_root)

      backend = :claude
      binary = Path.join(test_root, "routed-#{backend}")
      trace_file = Path.join(test_root, "trace-#{backend}.log")
      issue = issue_fixture(backend)

      File.write!(binary, fake_backend_script(backend, trace_file))
      File.chmod!(binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "missing-default-backend app-server",
        codex_command_by_label: %{"backend:claude" => "#{binary} app-server"}
      )

      assert :ok =
               AgentRunner.run(
                 issue,
                 nil,
                 max_turns: 1,
                 issue_state_fetcher: fn _issue_ids -> {:ok, []} end
               )

      trace = File.read!(trace_file)
      assert trace =~ ~s("title":"#{issue.identifier}: #{issue.title}")
    after
      File.rm_rf(test_root)
    end
  end

  defp issue_fixture(backend) do
    %Issue{
      id: "issue-#{backend}",
      identifier: "BUB-87-#{String.upcase(to_string(backend))}",
      title: "Concurrent backend #{backend}",
      description: "Ensure backend #{backend} run stays isolated",
      state: "In Progress",
      url: "https://example.org/issues/BUB-87",
      labels: ["backend:#{backend}"]
    }
  end

  defp fake_backend_script(backend, trace_file) do
    """
    #!/bin/sh
    trace_file="#{trace_file}"
    count=0
    while IFS= read -r line; do
      count=$((count + 1))
      printf 'JSON:%s\\n' "$line" >> "$trace_file"
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-#{backend}"}}}'
          ;;
        3)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-#{backend}"}}}'
          ;;
        4)
          printf '%s\\n' '{"method":"turn/completed"}'
          exit 0
          ;;
        *)
          exit 0
          ;;
      esac
    done
    """
  end
end
