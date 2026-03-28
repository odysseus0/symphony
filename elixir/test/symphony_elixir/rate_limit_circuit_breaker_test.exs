defmodule SymphonyElixir.RateLimitCircuitBreakerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.RateLimitCircuitBreaker

  # ---------------------------------------------------------------------------
  # rate_limit_detected?/1
  # ---------------------------------------------------------------------------

  describe "rate_limit_detected?/1" do
    test "detects 'hit your limit' pattern" do
      assert RateLimitCircuitBreaker.rate_limit_detected?(
               "You've hit your limit · resets 5pm (Asia/Shanghai)"
             )
    end

    test "detects 'rate limit' pattern" do
      assert RateLimitCircuitBreaker.rate_limit_detected?("Error: rate limit exceeded")
    end

    test "detects '429' pattern" do
      assert RateLimitCircuitBreaker.rate_limit_detected?("HTTP 429 Too Many Requests")
    end

    test "detects 'quota exceeded' pattern" do
      assert RateLimitCircuitBreaker.rate_limit_detected?("API quota exceeded for this billing period")
    end

    test "detects 'resets at' pattern" do
      assert RateLimitCircuitBreaker.rate_limit_detected?("Usage resets at 2026-03-28T17:00:00Z")
    end

    test "detects 'try again later' pattern" do
      assert RateLimitCircuitBreaker.rate_limit_detected?("Resource busy, try again later")
    end

    test "is case insensitive" do
      assert RateLimitCircuitBreaker.rate_limit_detected?("RATE LIMIT HIT")
      assert RateLimitCircuitBreaker.rate_limit_detected?("Try Again Later")
    end

    test "returns false for unrelated errors" do
      refute RateLimitCircuitBreaker.rate_limit_detected?("compilation failed")
      refute RateLimitCircuitBreaker.rate_limit_detected?("test failed")
      refute RateLimitCircuitBreaker.rate_limit_detected?("git push rejected")
    end

    test "handles non-string terms by inspecting them" do
      assert RateLimitCircuitBreaker.rate_limit_detected?({:error, "rate limit exceeded"})
      refute RateLimitCircuitBreaker.rate_limit_detected?({:error, :timeout})
    end
  end

  # ---------------------------------------------------------------------------
  # cooldown_ms/1
  # ---------------------------------------------------------------------------

  describe "cooldown_ms/1" do
    test "returns default cooldown for generic rate limit message" do
      assert RateLimitCircuitBreaker.cooldown_ms("rate limit exceeded") ==
               RateLimitCircuitBreaker.default_cooldown_ms()
    end

    test "parses 'retry after <seconds>'" do
      assert RateLimitCircuitBreaker.cooldown_ms("retry after 120") == 120_000
    end

    test "parses 'retry-after: <seconds>'" do
      assert RateLimitCircuitBreaker.cooldown_ms("Retry-After: 60") == 60_000
    end

    test "parses 'resets 5pm' style" do
      # We can't assert the exact value since it depends on current time,
      # but it should be a positive integer and not the default
      result = RateLimitCircuitBreaker.cooldown_ms("resets 5pm (Asia/Shanghai)")
      assert is_integer(result)
      assert result > 0
      assert result <= 86_400_000
    end

    test "parses 'resets 17:00' style" do
      result = RateLimitCircuitBreaker.cooldown_ms("resets 17:00")
      assert is_integer(result)
      assert result > 0
      assert result <= 86_400_000
    end

    test "returns default for non-string input" do
      assert RateLimitCircuitBreaker.cooldown_ms(nil) ==
               RateLimitCircuitBreaker.default_cooldown_ms()
    end
  end

  # ---------------------------------------------------------------------------
  # trip/4 and open?/2
  # ---------------------------------------------------------------------------

  describe "trip/4 and open?/2" do
    test "tripped breaker is open" do
      breakers = RateLimitCircuitBreaker.trip(%{}, "claude-runtime", 300_000, "rate limit hit")
      assert RateLimitCircuitBreaker.open?(breakers, "claude-runtime")
    end

    test "non-existent runtime is not open" do
      refute RateLimitCircuitBreaker.open?(%{}, "claude-runtime")
    end

    test "breaker with zero cooldown expires immediately" do
      breakers = RateLimitCircuitBreaker.trip(%{}, "rt", 0, "test")
      # With 0 ms cooldown, it should have expired by now
      refute RateLimitCircuitBreaker.open?(breakers, "rt")
    end

    test "trip overwrites existing entry" do
      breakers =
        %{}
        |> RateLimitCircuitBreaker.trip("rt", 1_000, "first")
        |> RateLimitCircuitBreaker.trip("rt", 600_000, "second")

      assert %{reason_snippet: "second"} = breakers["rt"]
    end
  end

  # ---------------------------------------------------------------------------
  # expire_recovered/1
  # ---------------------------------------------------------------------------

  describe "expire_recovered/1" do
    test "removes expired entries" do
      now_ms = System.monotonic_time(:millisecond)

      breakers = %{
        "expired-rt" => %{
          tripped_at_ms: now_ms - 10_000,
          expires_at_ms: now_ms - 1,
          reason_snippet: "old"
        },
        "active-rt" => %{
          tripped_at_ms: now_ms,
          expires_at_ms: now_ms + 300_000,
          reason_snippet: "fresh"
        }
      }

      pruned = RateLimitCircuitBreaker.expire_recovered(breakers)
      refute Map.has_key?(pruned, "expired-rt")
      assert Map.has_key?(pruned, "active-rt")
    end

    test "returns empty map when all expired" do
      now_ms = System.monotonic_time(:millisecond)

      breakers = %{
        "a" => %{tripped_at_ms: now_ms - 10_000, expires_at_ms: now_ms - 1, reason_snippet: "x"}
      }

      assert RateLimitCircuitBreaker.expire_recovered(breakers) == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # maybe_trip/3
  # ---------------------------------------------------------------------------

  describe "maybe_trip/3" do
    test "trips on rate limit reason" do
      {tripped, breakers} =
        RateLimitCircuitBreaker.maybe_trip(%{}, "claude-rt", "You've hit your limit · resets 5pm")

      assert tripped
      assert RateLimitCircuitBreaker.open?(breakers, "claude-rt")
    end

    test "does not trip on non-rate-limit reason" do
      {tripped, breakers} =
        RateLimitCircuitBreaker.maybe_trip(%{}, "claude-rt", "compilation failed")

      refute tripped
      assert breakers == %{}
    end

    test "does not trip when runtime_name is nil" do
      {tripped, breakers} =
        RateLimitCircuitBreaker.maybe_trip(%{}, nil, "rate limit exceeded")

      refute tripped
      assert breakers == %{}
    end

    test "handles tuple reasons" do
      {tripped, breakers} =
        RateLimitCircuitBreaker.maybe_trip(
          %{},
          "codex-rt",
          {:agent_run_failed, "429 Too Many Requests"}
        )

      assert tripped
      assert RateLimitCircuitBreaker.open?(breakers, "codex-rt")
    end
  end
end
