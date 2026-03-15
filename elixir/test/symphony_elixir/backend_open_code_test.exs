defmodule SymphonyElixir.BackendOpenCodeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Backend.OpenCode

  test "opencode backend performs initialize + session/new + session/prompt flow" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-backend-success-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "BUB-83")
      opencode_binary = Path.join(test_root, "fake-opencode")
      trace_file = Path.join(test_root, "opencode.trace")
      previous_trace = System.get_env("SYMP_TEST_OPENCODE_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_OPENCODE_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_OPENCODE_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_OPENCODE_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(opencode_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_OPENCODE_TRACE:-/tmp/opencode.trace}"

      while IFS= read -r line; do
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
            ;;
          *'"method":"session/new"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-83"}}'
            ;;
          *'"method":"session/prompt"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"session-83","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"done"}}}}'
            printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn","usage":{"totalTokens":10,"inputTokens":4,"outputTokens":6}}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(opencode_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_backend: "opencode",
        codex_opencode_command: "#{opencode_binary} acp",
        codex_opencode_mcp_servers: [%{name: "noop", command: "/usr/bin/true", args: [], env: []}]
      )

      issue = %Issue{
        id: "issue-opencode-success",
        identifier: "BUB-83",
        title: "OpenCode flow",
        description: "Run one ACP turn",
        state: "In Progress",
        url: "https://example.org/issues/BUB-83",
        labels: ["feature"]
      }

      on_message = fn message -> send(self(), {:open_code_message, message}) end

      assert {:ok, session} = OpenCode.start_session(workspace)
      assert {:ok, result} = OpenCode.run_turn(session, "reply with done", issue, on_message: on_message)
      assert :ok = OpenCode.stop_session(session)

      assert result.thread_id == "session-83"
      assert result.result["stopReason"] == "end_turn"
      assert result.result["usage"]["totalTokens"] == 10

      assert_received {:open_code_message, %{event: :session_started}}
      assert_received {:open_code_message, %{event: :opencode_session_update, update_kind: "agent_message_chunk"}}
      assert_received {:open_code_message, %{event: :turn_completed}}

      trace =
        trace_file
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.starts_with?(&1, "JSON:"))
        |> Enum.map(&(String.trim_leading(&1, "JSON:") |> Jason.decode!()))

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert Enum.any?(trace, &(&1["method"] == "initialize"))

      assert Enum.any?(trace, fn payload ->
               payload["method"] == "session/new" and
                 get_in(payload, ["params", "cwd"]) == canonical_workspace
             end)

      assert Enum.any?(trace, fn payload ->
               payload["method"] == "session/new" and
                 get_in(payload, ["params", "mcpServers"]) == [
                   %{"name" => "noop", "command" => "/usr/bin/true", "args" => [], "env" => []}
                 ]
             end)

      assert Enum.any?(trace, fn payload ->
               payload["method"] == "session/prompt" and
                 get_in(payload, ["params", "prompt"]) == [%{"type" => "text", "text" => "reply with done"}]
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "opencode backend reports process exit while waiting for turn completion" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-backend-crash-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "BUB-83")
      opencode_binary = Path.join(test_root, "fake-opencode")
      File.mkdir_p!(workspace)

      File.write!(opencode_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
            ;;
          *'"method":"session/new"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"session-crash"}}'
            ;;
          *'"method":"session/prompt"'*)
            exit 1
            ;;
        esac
      done
      """)

      File.chmod!(opencode_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_backend: "opencode",
        codex_opencode_command: "#{opencode_binary} acp"
      )

      issue = %Issue{
        id: "issue-opencode-crash",
        identifier: "BUB-83",
        title: "OpenCode crash",
        description: "Exit mid turn",
        state: "In Progress",
        url: "https://example.org/issues/BUB-83",
        labels: ["feature"]
      }

      assert {:ok, session} = OpenCode.start_session(workspace)
      assert {:error, {:port_exit, 1}} = OpenCode.run_turn(session, "trigger crash", issue)
      assert :ok = OpenCode.stop_session(session)
    after
      File.rm_rf(test_root)
    end
  end

  test "opencode backend rejects invalid session/new payloads" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-opencode-backend-invalid-session-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "BUB-83")
      opencode_binary = Path.join(test_root, "fake-opencode")
      File.mkdir_p!(workspace)

      File.write!(opencode_binary, """
      #!/bin/sh
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
            ;;
          *'"method":"session/new"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"unexpected":true}}'
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(opencode_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_backend: "opencode",
        codex_opencode_command: "#{opencode_binary} acp"
      )

      assert {:error, {:invalid_session_payload, %{"unexpected" => true}}} =
               OpenCode.start_session(workspace)
    after
      File.rm_rf(test_root)
    end
  end
end
