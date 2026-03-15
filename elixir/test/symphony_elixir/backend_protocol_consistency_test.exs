defmodule SymphonyElixir.BackendProtocolConsistencyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AgentBackends

  @codex_raw_events [
    %{"method" => "thread/started"},
    %{"method" => "turn/started"},
    %{"method" => "item/agentMessage/delta", "params" => %{"delta" => "working"}},
    %{"method" => "item/tool/call", "params" => %{"tool" => "exec_command"}},
    %{"method" => "turn/completed"}
  ]

  @opencode_raw_events [
    %{"event" => "session.started"},
    %{"event" => "turn.started"},
    %{"event" => "message.delta", "text" => "working"},
    %{"event" => "tool.call", "name" => "exec_command"},
    %{"event" => "turn.completed"}
  ]

  @claude_raw_events [
    %{"type" => "session_started"},
    %{"type" => "turn_started"},
    %{"type" => "content_delta", "delta" => "working"},
    %{"type" => "tool_use", "name" => "exec_command"},
    %{"type" => "turn_completed"}
  ]

  test "normalizes each backend stream into equivalent canonical events" do
    codex = AgentBackends.normalize_stream(:codex, "BUB-87-CODEX", @codex_raw_events)
    opencode = AgentBackends.normalize_stream(:opencode, "BUB-87-OPENCODE", @opencode_raw_events)
    claude = AgentBackends.normalize_stream(:claude, "BUB-87-CLAUDE", @claude_raw_events)

    assert semantic_projection(codex) == semantic_projection(opencode)
    assert semantic_projection(codex) == semantic_projection(claude)
  end

  test "concurrent mixed streams stay isolated by issue and backend" do
    workloads = [
      {:codex, "BUB-87-A", @codex_raw_events},
      {:opencode, "BUB-87-B", @opencode_raw_events},
      {:claude, "BUB-87-C", @claude_raw_events}
    ]

    results =
      workloads
      |> Task.async_stream(
        fn {backend, issue_id, events} ->
          normalized = AgentBackends.normalize_stream(backend, issue_id, events)
          {backend, issue_id, normalized}
        end,
        timeout: 5_000,
        ordered: false
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert length(results) == 3

    Enum.each(results, fn {backend, issue_id, normalized} ->
      assert Enum.all?(normalized, fn event ->
               event.backend == backend and event.issue_id == issue_id
             end)
    end)
  end

  defp semantic_projection(events) do
    Enum.map(events, fn event ->
      %{event: event.event, message: event.message, tool: event.tool}
    end)
  end
end
