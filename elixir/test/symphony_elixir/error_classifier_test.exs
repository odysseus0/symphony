defmodule SymphonyElixir.ErrorClassifierTest do
  use ExUnit.Case

  alias SymphonyElixir.ErrorClassifier

  test "classifies compile errors as permanent" do
    reason = {:agent_run_failed, {:workspace_hook_failed, "before_run", 1, "CompileError: undefined function"}}
    assert ErrorClassifier.classify(reason) == :permanent
  end

  test "classifies test and git push failures as semi_permanent" do
    assert ErrorClassifier.classify("mix test failed") == :semi_permanent
    assert ErrorClassifier.classify("git push rejected (non-fast-forward)") == :semi_permanent
  end

  test "classifies rate limits and timeouts as transient" do
    assert ErrorClassifier.classify("HTTP 429 rate limit exhausted") == :transient
    assert ErrorClassifier.classify({:turn_failed, %{message: "request timed out"}}) == :transient
  end

  test "enforces semi-permanent retry limit" do
    assert ErrorClassifier.retry_allowed?(:semi_permanent, 1)
    assert ErrorClassifier.retry_allowed?(:semi_permanent, 3)
    refute ErrorClassifier.retry_allowed?(:semi_permanent, 4)
  end
end
