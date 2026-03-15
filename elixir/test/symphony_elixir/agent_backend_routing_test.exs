defmodule SymphonyElixir.AgentBackendRoutingTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  defmodule StubBackend do
    @behaviour SymphonyElixir.AgentBackend

    def start_session(workspace) do
      send(self(), {:stub_backend, :start_session, workspace})
      {:ok, %{workspace: workspace}}
    end

    def run_turn(session, prompt, issue, opts) do
      send(self(), {:stub_backend, :run_turn, session, prompt, issue})

      on_message = Keyword.get(opts, :on_message, fn _message -> :ok end)

      on_message.(%{
        event: :session_started,
        timestamp: DateTime.utc_now(),
        payload: %{session_id: "stub-thread-stub-turn", backend: "stub"}
      })

      {:ok, %{session_id: "stub-thread-stub-turn"}}
    end

    def stop_session(session) do
      send(self(), {:stub_backend, :stop_session, session})
      :ok
    end
  end

  test "agent config defaults backend to codex" do
    assert Config.settings!().agent.backend == "codex"
  end

  test "agent runner uses configured backend module" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "SymphonyElixir.AgentBackendRoutingTest.StubBackend"
    )

    issue = %Issue{
      id: "issue-stub-backend",
      identifier: "MT-AGENT-BACKEND",
      title: "Use configured backend",
      description: "Ensure runner calls the configured backend implementation",
      state: "In Progress",
      url: "https://example.org/issues/MT-AGENT-BACKEND",
      labels: ["backend"]
    }

    state_fetcher = fn [_issue_id] ->
      {:ok, [%{issue | state: "Done"}]}
    end

    assert :ok = AgentRunner.run(issue, self(), issue_state_fetcher: state_fetcher, max_turns: 1)

    assert_received {:stub_backend, :start_session, _workspace}
    assert_received {:stub_backend, :run_turn, _session, _prompt, %Issue{id: "issue-stub-backend"}}
    assert_received {:stub_backend, :stop_session, _session}

    assert_received {:codex_worker_update, "issue-stub-backend",
                     %{
                       event: :session_started,
                       timestamp: %DateTime{},
                       payload: %{session_id: "stub-thread-stub-turn", backend: "stub"}
                     }}
  end

  test "config validation rejects unsupported backend modules" do
    write_workflow_file!(Workflow.workflow_file_path(),
      agent_backend: "SymphonyElixir.Backend.DoesNotExist"
    )

    assert {:error, {:unsupported_agent_backend, "SymphonyElixir.Backend.DoesNotExist", _reason}} =
             Config.validate!()
  end
end
