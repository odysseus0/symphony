defmodule SymphonyElixir.MultiBackendFallbackTest do
  use SymphonyElixir.TestSupport

  @backends [:codex, :opencode, :claude]

  for backend <- @backends do
    test "fallback handles startup failure for #{backend}" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-backend-startup-fallback-#{unquote(backend)}-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-#{String.upcase(to_string(unquote(backend)))}")
        File.mkdir_p!(workspace)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "missing-#{unquote(backend)}-backend-command app-server",
          codex_read_timeout_ms: 200
        )

        issue = issue_fixture(unquote(backend), "startup failure")

        assert {:error, reason} =
                 AppServer.run(workspace, "Exercise startup fallback path", issue)

        assert startup_unavailable_reason?(reason)
      after
        File.rm_rf(test_root)
      end
    end

    test "fallback handles turn timeout for #{backend}" do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-elixir-backend-timeout-fallback-#{unquote(backend)}-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-#{String.upcase(to_string(unquote(backend)))}")
        backend_binary = Path.join(test_root, "fake-#{unquote(backend)}")
        File.mkdir_p!(workspace)

        File.write!(backend_binary, hanging_backend_script())
        File.chmod!(backend_binary, 0o755)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{backend_binary} app-server",
          codex_read_timeout_ms: 200,
          codex_turn_timeout_ms: 150
        )

        issue = issue_fixture(unquote(backend), "timeout fallback")

        assert {:error, reason} =
                 AppServer.run(workspace, "Exercise timeout fallback path", issue)

        assert reason in [:turn_timeout, :response_timeout]
      after
        File.rm_rf(test_root)
      end
    end
  end

  defp issue_fixture(backend, suffix) do
    %Issue{
      id: "issue-#{backend}-#{suffix}",
      identifier: "BUB-87-#{String.upcase(to_string(backend))}",
      title: "Exercise #{backend} fallback #{suffix}",
      description: "Validate #{backend} backend unavailability fallback behavior",
      state: "In Progress",
      url: "https://example.org/issues/BUB-87",
      labels: ["backend:#{backend}"]
    }
  end

  defp hanging_backend_script do
    """
    #!/bin/sh
    count=0
    while IFS= read -r _line; do
      count=$((count + 1))
      case "$count" in
        1)
          printf '%s\\n' '{"id":1,"result":{}}'
          ;;
        2)
          :
          ;;
        3)
          printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-timeout"}}}'
          ;;
        4)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-timeout"}}}'
          ;;
        *)
          sleep 5
          ;;
      esac
    done
    """
  end

  defp startup_unavailable_reason?({:port_exit, _status}), do: true
  defp startup_unavailable_reason?({:port_command_failed, :port_closed}), do: true
  defp startup_unavailable_reason?(_reason), do: false
end
