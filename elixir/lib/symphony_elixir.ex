defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    children = [
      {Phoenix.PubSub, name: SymphonyElixir.PubSub},
      {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
      SymphonyElixir.WorkflowStore,
      SymphonyElixir.Orchestrator,
      SymphonyElixir.HttpServer,
      SymphonyElixir.StatusDashboard
    ]

    result =
      Supervisor.start_link(
        children,
        strategy: :one_for_one,
        name: SymphonyElixir.Supervisor
      )

    # After supervisor (and WorkflowStore) are running, load memory tracker issues
    # from the WORKFLOW.md config into Application env so Tracker.Memory can serve them.
    :ok = maybe_load_memory_tracker_issues()

    result
  end

  # When tracker.kind is "memory" and the WORKFLOW.md defines inline issues,
  # load them into Application env so Tracker.Memory can serve them.
  # Called after the supervisor starts so WorkflowStore is available.
  defp maybe_load_memory_tracker_issues do
    try do
      case SymphonyElixir.Config.settings() do
        {:ok, %{tracker: %{kind: "memory", memory_issues: [_ | _] = issues}}} ->
          loaded =
            Enum.map(issues, fn issue ->
              %SymphonyElixir.Linear.Issue{
                id: Map.get(issue, "id", Map.get(issue, :id, issue["identifier"] || "demo")),
                identifier: Map.get(issue, "identifier", Map.get(issue, :identifier, "")),
                title: Map.get(issue, "title", Map.get(issue, :title, "")),
                description: Map.get(issue, "description", Map.get(issue, :description, "")),
                state: Map.get(issue, "state", Map.get(issue, :state, "Todo")),
                priority: Map.get(issue, "priority", Map.get(issue, :priority, 0)),
                branch_name: Map.get(issue, "branch_name", Map.get(issue, :branch_name, nil)),
                url: Map.get(issue, "url", Map.get(issue, :url, "")),
                labels: []
              }
            end)

          existing = Application.get_env(:symphony_elixir, :memory_tracker_issues, [])

          if existing == [] do
            Application.put_env(:symphony_elixir, :memory_tracker_issues, loaded)
          end

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  @impl true
  def stop(_state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    :ok
  end
end
