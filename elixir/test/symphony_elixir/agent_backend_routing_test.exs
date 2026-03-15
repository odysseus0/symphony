defmodule SymphonyElixir.AgentBackendRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Issue

  test "resolve_provider returns correct modules" do
    assert {:ok, SymphonyElixir.Backend.Codex} = SymphonyElixir.AgentBackend.resolve_provider("codex")
    assert {:ok, SymphonyElixir.Backend.OpenCode} = SymphonyElixir.AgentBackend.resolve_provider("opencode")
    assert {:ok, SymphonyElixir.Backend.Claude} = SymphonyElixir.AgentBackend.resolve_provider("claude")
    assert {:error, {:unknown_provider, "invalid"}} = SymphonyElixir.AgentBackend.resolve_provider("invalid")
  end

  test "runtime provider validation rejects invalid providers" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "linear", "api_key" => "tok", "project_slug" => "proj"},
               "runtimes" => [%{"name" => "bad", "provider" => "invalid"}]
             })

    assert message =~ "provider"
  end

  test "runtime requires name and provider" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{
               "tracker" => %{"kind" => "linear", "api_key" => "tok", "project_slug" => "proj"},
               "runtimes" => [%{"command" => "codex app-server"}]
             })

    assert message =~ "name" or message =~ "provider"
  end

  test "label uniqueness validation catches duplicates" do
    runtimes = [
      %Schema.Runtime{name: "a", provider: "codex", labels: ["deploy"]},
      %Schema.Runtime{name: "b", provider: "claude", labels: ["deploy"]}
    ]

    assert {:error, {:duplicate_runtime_labels, ["deploy"]}} = Schema.validate_unique_labels(runtimes)
  end

  test "label uniqueness is case-insensitive" do
    runtimes = [
      %Schema.Runtime{name: "a", provider: "codex", labels: ["Deploy"]},
      %Schema.Runtime{name: "b", provider: "claude", labels: ["deploy"]}
    ]

    assert {:error, {:duplicate_runtime_labels, ["deploy"]}} = Schema.validate_unique_labels(runtimes)
  end

  test "label uniqueness passes with disjoint labels" do
    runtimes = [
      %Schema.Runtime{name: "a", provider: "codex", labels: ["backend"]},
      %Schema.Runtime{name: "b", provider: "claude", labels: ["frontend"]}
    ]

    assert :ok = Schema.validate_unique_labels(runtimes)
  end

  test "resolve_runtime_for_issue matches by label" do
    runtimes = [
      %Schema.Runtime{name: "codex-rt", provider: "codex", labels: ["backend"]},
      %Schema.Runtime{name: "claude-rt", provider: "claude", labels: ["frontend"]},
      %Schema.Runtime{name: "fallback", provider: "codex", labels: []}
    ]

    issue = %Issue{
      id: "i1", identifier: "T-1", title: "t", description: "d",
      state: "Todo", url: "http://example.com", labels: ["frontend"]
    }

    rt = Schema.resolve_runtime_for_issue(issue, runtimes)
    assert rt.name == "claude-rt"
  end

  test "resolve_runtime_for_issue falls back to empty-labels runtime" do
    runtimes = [
      %Schema.Runtime{name: "codex-rt", provider: "codex", labels: ["backend"]},
      %Schema.Runtime{name: "fallback", provider: "codex", labels: []}
    ]

    issue = %Issue{
      id: "i2", identifier: "T-2", title: "t", description: "d",
      state: "Todo", url: "http://example.com", labels: ["unknown"]
    }

    rt = Schema.resolve_runtime_for_issue(issue, runtimes)
    assert rt.name == "fallback"
  end

  test "resolve_runtime_for_issue returns nil when no match and no fallback" do
    runtimes = [
      %Schema.Runtime{name: "codex-rt", provider: "codex", labels: ["backend"]}
    ]

    issue = %Issue{
      id: "i3", identifier: "T-3", title: "t", description: "d",
      state: "Todo", url: "http://example.com", labels: ["unknown"]
    }

    assert is_nil(Schema.resolve_runtime_for_issue(issue, runtimes))
  end

  test "resolve_runtime_for_issue warns on multiple matches and picks first" do
    runtimes = [
      %Schema.Runtime{name: "first", provider: "codex", labels: ["shared"]},
      %Schema.Runtime{name: "second", provider: "claude", labels: ["shared"]}
    ]

    issue = %Issue{
      id: "i4", identifier: "T-4", title: "t", description: "d",
      state: "Todo", url: "http://example.com", labels: ["shared"]
    }

    log =
      capture_log(fn ->
        rt = Schema.resolve_runtime_for_issue(issue, runtimes)
        assert rt.name == "first"
      end)

    assert log =~ "Multiple runtimes matched"
  end

  test "empty runtimes config synthesizes default codex runtime" do
    settings = Config.settings!()
    assert length(settings.runtimes) == 1
    [default_rt] = settings.runtimes
    assert default_rt.name == "default"
    assert default_rt.provider == "codex"
    assert default_rt.labels == []
  end

  test "finalize_runtimes fills default command from provider" do
    write_workflow_file!(Workflow.workflow_file_path(),
      runtimes: [
        %{name: "claude-rt", provider: "claude", labels: ["claude"]},
        %{name: "opencode-rt", provider: "opencode", labels: ["opencode"]},
        %{name: "codex-rt", provider: "codex", labels: []}
      ]
    )

    settings = Config.settings!()
    runtimes = settings.runtimes

    claude_rt = Enum.find(runtimes, &(&1.name == "claude-rt"))
    assert claude_rt.command == "claude"

    opencode_rt = Enum.find(runtimes, &(&1.name == "opencode-rt"))
    assert opencode_rt.command == "opencode acp"

    codex_rt = Enum.find(runtimes, &(&1.name == "codex-rt"))
    assert codex_rt.command == "codex app-server"
  end
end
