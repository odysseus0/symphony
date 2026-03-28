defmodule SymphonyElixir.OrchestratorTerminalCacheTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp base_state do
    %State{
      poll_interval_ms: 5_000,
      max_concurrent_agents: 10,
      next_poll_due_at_ms: 0,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      workspace_usage_bytes: 0,
      workspace_usage_refresh_ref: nil,
      workspace_threshold_exceeded?: false,
      dispatch_cooldowns: %{},
      terminal_issue_ids: MapSet.new()
    }
  end

  defp make_issue(id, state_name) do
    %Issue{
      id: id,
      identifier: "BUB-#{id}",
      title: "Test issue #{id}",
      description: "Description",
      state: state_name,
      url: "https://example.org/issues/BUB-#{id}"
    }
  end

  # ---------------------------------------------------------------------------
  # mark_issue_terminal_for_test / clear_terminal_issue_id_for_test
  # ---------------------------------------------------------------------------

  describe "mark_issue_terminal_for_test/2" do
    test "adds issue_id to terminal_issue_ids" do
      state = Orchestrator.mark_issue_terminal_for_test(base_state(), "issue-1")
      assert MapSet.member?(state.terminal_issue_ids, "issue-1")
    end

    test "is idempotent for same issue_id" do
      state =
        base_state()
        |> Orchestrator.mark_issue_terminal_for_test("issue-1")
        |> Orchestrator.mark_issue_terminal_for_test("issue-1")

      assert MapSet.size(state.terminal_issue_ids) == 1
    end

    test "supports multiple issue_ids" do
      state =
        base_state()
        |> Orchestrator.mark_issue_terminal_for_test("issue-1")
        |> Orchestrator.mark_issue_terminal_for_test("issue-2")

      assert MapSet.member?(state.terminal_issue_ids, "issue-1")
      assert MapSet.member?(state.terminal_issue_ids, "issue-2")
      assert MapSet.size(state.terminal_issue_ids) == 2
    end
  end

  describe "clear_terminal_issue_id_for_test/2" do
    test "removes issue_id from terminal_issue_ids" do
      state =
        base_state()
        |> Orchestrator.mark_issue_terminal_for_test("issue-1")
        |> Orchestrator.clear_terminal_issue_id_for_test("issue-1")

      refute MapSet.member?(state.terminal_issue_ids, "issue-1")
    end

    test "is a no-op when issue_id not present" do
      state = Orchestrator.clear_terminal_issue_id_for_test(base_state(), "nonexistent")
      assert MapSet.size(state.terminal_issue_ids) == 0
    end

    test "only removes specified issue_id" do
      state =
        base_state()
        |> Orchestrator.mark_issue_terminal_for_test("issue-1")
        |> Orchestrator.mark_issue_terminal_for_test("issue-2")
        |> Orchestrator.clear_terminal_issue_id_for_test("issue-1")

      refute MapSet.member?(state.terminal_issue_ids, "issue-1")
      assert MapSet.member?(state.terminal_issue_ids, "issue-2")
    end
  end

  # ---------------------------------------------------------------------------
  # should_dispatch_issue? blocks dispatch for terminal-cached issues
  # ---------------------------------------------------------------------------

  describe "should_dispatch_issue_for_test with terminal cache" do
    test "allows dispatch when issue is not in terminal cache" do
      issue = make_issue("issue-1", "In Progress")
      state = base_state()
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "blocks dispatch when issue is in terminal cache" do
      issue = make_issue("issue-1", "In Progress")

      state = Orchestrator.mark_issue_terminal_for_test(base_state(), "issue-1")

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "allows dispatch after terminal cache is cleared" do
      issue = make_issue("issue-1", "In Progress")

      state =
        base_state()
        |> Orchestrator.mark_issue_terminal_for_test("issue-1")
        |> Orchestrator.clear_terminal_issue_id_for_test("issue-1")

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "only blocks the specific issue in terminal cache" do
      issue_1 = make_issue("issue-1", "In Progress")
      issue_2 = make_issue("issue-2", "In Progress")

      state = Orchestrator.mark_issue_terminal_for_test(base_state(), "issue-1")

      refute Orchestrator.should_dispatch_issue_for_test(issue_1, state)
      assert Orchestrator.should_dispatch_issue_for_test(issue_2, state)
    end
  end
end
