defmodule SymphonyElixir.OrchestratorCircuitBreakerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.State
  alias SymphonyElixir.RateLimitCircuitBreaker

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
      circuit_breakers: %{}
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

  defp make_running_entry(runtime_name, last_message \\ nil) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: "BUB-1",
      issue: make_issue("1", "In Progress"),
      trace_id: "trace-1",
      session_id: "session-1",
      last_codex_message: last_message,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      context_window_tokens: 400_000,
      context_usage_percent: 0.0,
      turn_count: 0,
      retry_attempt: 1,
      started_at: DateTime.utc_now(),
      runtime_name: runtime_name
    }
  end

  # ---------------------------------------------------------------------------
  # check_rate_limit_circuit_breaker_for_test — exit reason detection
  # ---------------------------------------------------------------------------

  describe "check_rate_limit_circuit_breaker_for_test/3 with exit reason" do
    test "trips breaker when exit reason contains rate limit text" do
      state = base_state()
      entry = make_running_entry("claude-sonnet")

      reason = {:agent_run_failed, "You've hit your limit · resets 5pm (Asia/Shanghai)"}
      updated = Orchestrator.check_rate_limit_circuit_breaker_for_test(state, entry, reason)

      assert RateLimitCircuitBreaker.open?(updated.circuit_breakers, "claude-sonnet")
    end

    test "does not trip breaker when exit reason is unrelated" do
      state = base_state()
      entry = make_running_entry("claude-sonnet")

      reason = {:agent_run_failed, "compilation failed"}
      updated = Orchestrator.check_rate_limit_circuit_breaker_for_test(state, entry, reason)

      refute RateLimitCircuitBreaker.open?(updated.circuit_breakers, "claude-sonnet")
    end

    test "does not trip breaker on normal exit with no rate-limit message" do
      state = base_state()
      entry = make_running_entry("claude-sonnet")

      updated = Orchestrator.check_rate_limit_circuit_breaker_for_test(state, entry, :normal)

      refute RateLimitCircuitBreaker.open?(updated.circuit_breakers, "claude-sonnet")
    end
  end

  # ---------------------------------------------------------------------------
  # check_rate_limit_circuit_breaker_for_test — last message detection
  # ---------------------------------------------------------------------------

  describe "check_rate_limit_circuit_breaker_for_test/3 with last_codex_message" do
    test "trips breaker when last message contains rate limit text (normal exit)" do
      state = base_state()

      last_msg = %{
        event: "message",
        message: "You've hit your limit · resets 5pm (Asia/Shanghai)",
        timestamp: DateTime.utc_now()
      }

      entry = make_running_entry("claude-sonnet", last_msg)

      updated = Orchestrator.check_rate_limit_circuit_breaker_for_test(state, entry, :normal)

      assert RateLimitCircuitBreaker.open?(updated.circuit_breakers, "claude-sonnet")
    end

    test "does not trip breaker when last message is normal text" do
      state = base_state()

      last_msg = %{
        event: "message",
        message: "Task completed successfully.",
        timestamp: DateTime.utc_now()
      }

      entry = make_running_entry("claude-sonnet", last_msg)

      updated = Orchestrator.check_rate_limit_circuit_breaker_for_test(state, entry, :normal)

      refute RateLimitCircuitBreaker.open?(updated.circuit_breakers, "claude-sonnet")
    end
  end

  # ---------------------------------------------------------------------------
  # should_dispatch_issue_for_test — circuit breaker blocks dispatch
  # ---------------------------------------------------------------------------

  describe "should_dispatch_issue_for_test with circuit breakers" do
    test "blocks dispatch when runtime is circuit-broken" do
      # Reconfigure workflow with a runtime that matches the label
      workflow_root = Path.join(System.tmp_dir!(), "symphony-cb-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")
      Workflow.set_workflow_file_path(workflow_file)

      write_workflow_file!(workflow_file,
        runtimes: [
          %{name: "claude-sonnet", provider: "claude", labels: ["backend:claude"]}
        ]
      )

      issue = %Issue{
        make_issue("issue-1", "In Progress")
        | labels: ["backend:claude"]
      }

      now_ms = System.monotonic_time(:millisecond)

      state = %{
        base_state()
        | circuit_breakers: %{
            "claude-sonnet" => %{
              tripped_at_ms: now_ms,
              expires_at_ms: now_ms + 300_000,
              reason_snippet: "rate limit"
            }
          }
      }

      refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "allows dispatch when circuit breaker has expired" do
      workflow_root = Path.join(System.tmp_dir!(), "symphony-cb-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(workflow_root)
      workflow_file = Path.join(workflow_root, "WORKFLOW.md")
      Workflow.set_workflow_file_path(workflow_file)

      write_workflow_file!(workflow_file,
        runtimes: [
          %{name: "claude-sonnet", provider: "claude", labels: ["backend:claude"]}
        ]
      )

      issue = %Issue{
        make_issue("issue-1", "In Progress")
        | labels: ["backend:claude"]
      }

      now_ms = System.monotonic_time(:millisecond)

      state = %{
        base_state()
        | circuit_breakers: %{
            "claude-sonnet" => %{
              tripped_at_ms: now_ms - 400_000,
              expires_at_ms: now_ms - 1,
              reason_snippet: "rate limit"
            }
          }
      }

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end

    test "allows dispatch when no circuit breaker exists" do
      issue = make_issue("issue-1", "In Progress")
      state = base_state()

      assert Orchestrator.should_dispatch_issue_for_test(issue, state)
    end
  end

  # ---------------------------------------------------------------------------
  # expire_circuit_breakers_for_test
  # ---------------------------------------------------------------------------

  describe "expire_circuit_breakers_for_test/1" do
    test "removes expired entries from state" do
      now_ms = System.monotonic_time(:millisecond)

      state = %{
        base_state()
        | circuit_breakers: %{
            "expired-rt" => %{
              tripped_at_ms: now_ms - 600_000,
              expires_at_ms: now_ms - 1,
              reason_snippet: "old"
            },
            "active-rt" => %{
              tripped_at_ms: now_ms,
              expires_at_ms: now_ms + 300_000,
              reason_snippet: "fresh"
            }
          }
      }

      updated = Orchestrator.expire_circuit_breakers_for_test(state)
      refute Map.has_key?(updated.circuit_breakers, "expired-rt")
      assert Map.has_key?(updated.circuit_breakers, "active-rt")
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple runtimes isolation
  # ---------------------------------------------------------------------------

  describe "circuit breaker isolation between runtimes" do
    test "breaking one runtime does not affect another" do
      state = base_state()
      entry_claude = make_running_entry("claude-sonnet")
      entry_codex = make_running_entry("codex-default")

      # Trip claude's breaker
      reason = "429 rate limit"
      updated = Orchestrator.check_rate_limit_circuit_breaker_for_test(state, entry_claude, reason)

      assert RateLimitCircuitBreaker.open?(updated.circuit_breakers, "claude-sonnet")
      refute RateLimitCircuitBreaker.open?(updated.circuit_breakers, "codex-default")

      # Trip codex's breaker too
      updated2 = Orchestrator.check_rate_limit_circuit_breaker_for_test(updated, entry_codex, reason)
      assert RateLimitCircuitBreaker.open?(updated2.circuit_breakers, "claude-sonnet")
      assert RateLimitCircuitBreaker.open?(updated2.circuit_breakers, "codex-default")
    end
  end
end
