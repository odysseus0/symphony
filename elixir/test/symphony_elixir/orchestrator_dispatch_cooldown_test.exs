defmodule SymphonyElixir.OrchestratorDispatchCooldownTest do
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
      dispatch_cooldowns: %{}
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
  # dispatch_cooldown_delay_ms/1
  # ---------------------------------------------------------------------------

  describe "dispatch_cooldown_delay_ms/1" do
    test "returns 0 for zero attempts" do
      assert Orchestrator.dispatch_cooldown_delay_ms(0) == 0
    end

    test "returns 30s for first attempt" do
      assert Orchestrator.dispatch_cooldown_delay_ms(1) == 30_000
    end

    test "doubles on each subsequent attempt" do
      assert Orchestrator.dispatch_cooldown_delay_ms(2) == 60_000
      assert Orchestrator.dispatch_cooldown_delay_ms(3) == 120_000
      assert Orchestrator.dispatch_cooldown_delay_ms(4) == 240_000
    end

    test "caps at 5 minutes" do
      assert Orchestrator.dispatch_cooldown_delay_ms(5) == 300_000
      assert Orchestrator.dispatch_cooldown_delay_ms(6) == 300_000
      assert Orchestrator.dispatch_cooldown_delay_ms(10) == 300_000
      assert Orchestrator.dispatch_cooldown_delay_ms(20) == 300_000
    end
  end

  # ---------------------------------------------------------------------------
  # record / reset cooldown via test helpers
  # ---------------------------------------------------------------------------

  describe "record_dispatch_cooldown_for_test/2" do
    test "records first dispatch with attempts = 1" do
      issue = make_issue("issue-1", "Auto Review")
      state = Orchestrator.record_dispatch_cooldown_for_test(base_state(), issue)

      assert %{attempts: 1, last_state: "auto review"} = state.dispatch_cooldowns["issue-1"]
      assert is_integer(state.dispatch_cooldowns["issue-1"].last_dispatched_at_ms)
    end

    test "increments attempts on repeated dispatch in same state" do
      issue = make_issue("issue-1", "Auto Review")

      state =
        base_state()
        |> Orchestrator.record_dispatch_cooldown_for_test(issue)
        |> Orchestrator.record_dispatch_cooldown_for_test(issue)
        |> Orchestrator.record_dispatch_cooldown_for_test(issue)

      assert %{attempts: 3, last_state: "auto review"} = state.dispatch_cooldowns["issue-1"]
    end

    test "resets attempts when issue state changes" do
      issue_v1 = make_issue("issue-1", "Auto Review")
      issue_v2 = make_issue("issue-1", "In Progress")

      state =
        base_state()
        |> Orchestrator.record_dispatch_cooldown_for_test(issue_v1)
        |> Orchestrator.record_dispatch_cooldown_for_test(issue_v1)
        |> Orchestrator.record_dispatch_cooldown_for_test(issue_v2)

      assert %{attempts: 1, last_state: "in progress"} = state.dispatch_cooldowns["issue-1"]
    end
  end

  describe "reset_dispatch_cooldown_for_test/2" do
    test "removes cooldown entry for issue" do
      issue = make_issue("issue-1", "Auto Review")

      state =
        base_state()
        |> Orchestrator.record_dispatch_cooldown_for_test(issue)
        |> Orchestrator.reset_dispatch_cooldown_for_test("issue-1")

      refute Map.has_key?(state.dispatch_cooldowns, "issue-1")
    end

    test "is a no-op when issue has no cooldown" do
      state = Orchestrator.reset_dispatch_cooldown_for_test(base_state(), "nonexistent")
      assert state.dispatch_cooldowns == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # should_dispatch_issue? integration via should_dispatch_issue_for_test
  # ---------------------------------------------------------------------------

  describe "should_dispatch_issue_for_test with cooldowns" do
    test "allows dispatch when no cooldown is recorded" do
      issue = make_issue("issue-1", "In Progress")
      state = base_state()
      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "blocks dispatch during active cooldown" do
      issue = make_issue("issue-1", "In Progress")

      # Record a dispatch — the cooldown for attempt 1 is 30s, which hasn't elapsed
      state = Orchestrator.record_dispatch_cooldown_for_test(base_state(), issue)

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "allows dispatch when cooldown has expired" do
      issue = make_issue("issue-1", "In Progress")
      now_ms = System.monotonic_time(:millisecond)

      # Simulate a cooldown that expired 1 second ago (attempt 1 → 30s cooldown)
      state = %{
        base_state()
        | dispatch_cooldowns: %{
            "issue-1" => %{
              last_dispatched_at_ms: now_ms - 31_000,
              attempts: 1,
              last_state: "in progress"
            }
          }
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "blocks dispatch when cooldown has not yet expired" do
      issue = make_issue("issue-1", "In Progress")
      now_ms = System.monotonic_time(:millisecond)

      # Simulate a cooldown that still has 20s remaining (attempt 1 → 30s cooldown)
      state = %{
        base_state()
        | dispatch_cooldowns: %{
            "issue-1" => %{
              last_dispatched_at_ms: now_ms - 10_000,
              attempts: 1,
              last_state: "in progress"
            }
          }
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "allows dispatch when issue state has changed since last cooldown" do
      issue = make_issue("issue-1", "In Progress")
      now_ms = System.monotonic_time(:millisecond)

      # Cooldown was recorded for "auto review", but issue is now "in progress"
      state = %{
        base_state()
        | dispatch_cooldowns: %{
            "issue-1" => %{
              last_dispatched_at_ms: now_ms,
              attempts: 5,
              last_state: "auto review"
            }
          }
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "exponential backoff requires longer wait for higher attempt counts" do
      issue = make_issue("issue-1", "In Progress")
      now_ms = System.monotonic_time(:millisecond)

      # Attempt 3 → 120s cooldown; 90s have passed — should still be blocked
      state = %{
        base_state()
        | dispatch_cooldowns: %{
            "issue-1" => %{
              last_dispatched_at_ms: now_ms - 90_000,
              attempts: 3,
              last_state: "in progress"
            }
          }
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)

      # But after 120s it should be allowed
      state_expired = %{
        base_state()
        | dispatch_cooldowns: %{
            "issue-1" => %{
              last_dispatched_at_ms: now_ms - 121_000,
              attempts: 3,
              last_state: "in progress"
            }
          }
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state_expired)
    end
  end
end
