defmodule SymphonyElixir.BackendClaudeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Backend.Claude

  test "claude backend runs a complete turn with stream-json output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-backend-success-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "BUB-84")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      # Emit stream-json NDJSON
      printf '%s\\n' '{"type":"system","subtype":"init","session_id":"test-session"}'
      printf '%s\\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."}]}}'
      printf '%s\\n' '{"type":"result","subtype":"success","session_id":"test-session","cost_usd":0.01,"duration_ms":500,"num_turns":1,"is_error":false}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-claude-success",
        identifier: "BUB-84",
        title: "Claude flow",
        description: "Run one CLI turn",
        state: "In Progress",
        url: "https://example.org/issues/BUB-84",
        labels: ["feature"]
      }

      on_message = fn message -> send(self(), {:claude_message, message}) end

      assert {:ok, session} = Claude.start_session(workspace, command: fake_claude)
      assert {:ok, result} = Claude.run_turn(session, "reply with done", issue, on_message: on_message)
      assert :ok = Claude.stop_session(session)

      assert result.session_id == session.session_id
      assert result.result["subtype"] == "success"

      assert_received {:claude_message, %{event: :session_started}}
      assert_received {:claude_message, %{event: :system_init}}
      assert_received {:claude_message, %{event: :agent_message}}
      assert_received {:claude_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend reports process exit on failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-backend-crash-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "BUB-84")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      exit 1
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-claude-crash",
        identifier: "BUB-84",
        title: "Claude crash",
        description: "Exit immediately",
        state: "In Progress",
        url: "https://example.org/issues/BUB-84",
        labels: ["feature"]
      }

      assert {:ok, session} = Claude.start_session(workspace, command: fake_claude)
      assert {:error, {:port_exit, 1}} = Claude.run_turn(session, "trigger crash", issue)
      assert :ok = Claude.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend handles error result from CLI" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-claude-backend-error-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "BUB-84")
      fake_claude = Path.join(test_root, "fake-claude")
      File.mkdir_p!(workspace)

      File.write!(fake_claude, """
      #!/bin/sh
      printf '%s\\n' '{"type":"result","subtype":"error","error":"rate_limited","session_id":"test-err"}'
      exit 0
      """)

      File.chmod!(fake_claude, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-claude-error",
        identifier: "BUB-84",
        title: "Claude error",
        description: "Return error result",
        state: "In Progress",
        url: "https://example.org/issues/BUB-84",
        labels: ["feature"]
      }

      assert {:ok, session} = Claude.start_session(workspace, command: fake_claude)
      assert {:error, {:turn_failed, "rate_limited"}} = Claude.run_turn(session, "fail", issue)
      assert :ok = Claude.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "claude backend resolves via AgentBackend.resolve_provider" do
    assert {:ok, SymphonyElixir.Backend.Claude} = SymphonyElixir.AgentBackend.resolve_provider("claude")
  end
end
