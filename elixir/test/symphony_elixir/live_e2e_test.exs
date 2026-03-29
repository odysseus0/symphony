defmodule SymphonyElixir.LiveE2ETest do
  use SymphonyElixir.TestSupport

  require Logger

  @moduletag :live_e2e
  @moduletag timeout: 300_000

  # ── Matrix dimensions ──

  @trackers [:linear, :plane]
  @backends [:codex, :opencode, :claude]

  # ── Linear defaults ──

  @default_linear_team_key "SYME2E"

  # ── Plane defaults ──

  @default_plane_base_url "http://localhost"
  @default_plane_workspace_slug "ant"
  @default_plane_project_id "5f4989a5-1509-42db-be77-3afb96e1429c"

  # ── Skip logic ──

  backend_skip_reason = fn backend ->
    {command, required_env_var} =
      case backend do
        :codex ->
          {System.get_env("SYMPHONY_LIVE_CODEX_COMMAND") || "codex app-server", nil}

        :opencode ->
          {System.get_env("SYMPHONY_LIVE_OPENCODE_COMMAND"), "SYMPHONY_LIVE_OPENCODE_COMMAND"}

        :claude ->
          {System.get_env("SYMPHONY_LIVE_CLAUDE_COMMAND"), "SYMPHONY_LIVE_CLAUDE_COMMAND"}
      end

    executable =
      case command do
        value when is_binary(value) ->
          value |> String.trim() |> String.split(~r/\s+/, parts: 2, trim: true) |> List.first()

        _ ->
          nil
      end

    cond do
      System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1" ->
        "set SYMPHONY_RUN_LIVE_E2E=1 to enable live end-to-end tests"

      executable in [nil, ""] and is_binary(required_env_var) ->
        "live #{backend} test requires #{required_env_var}"

      executable in [nil, ""] ->
        "live #{backend} test requires a non-empty command"

      is_nil(System.find_executable(executable)) ->
        "live #{backend} test requires executable `#{executable}` on PATH"

      true ->
        nil
    end
  end

  tracker_skip_reason = fn tracker ->
    cond do
      System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1" ->
        "set SYMPHONY_RUN_LIVE_E2E=1 to enable live end-to-end tests"

      tracker == :linear and System.get_env("LINEAR_API_KEY") in [nil, ""] ->
        "Linear live tests require LINEAR_API_KEY"

      tracker == :plane and System.get_env("PLANE_API_KEY") in [nil, ""] ->
        "Plane live tests require PLANE_API_KEY"

      true ->
        nil
    end
  end

  @combo_skip_reasons (for tracker <- @trackers, backend <- @backends, into: %{} do
                         tracker_skip = tracker_skip_reason.(tracker)
                         backend_skip = backend_skip_reason.(backend)

                         skip =
                           cond do
                             is_binary(tracker_skip) -> tracker_skip
                             is_binary(backend_skip) -> backend_skip
                             true -> nil
                           end

                         {{tracker, backend}, skip}
                       end)

  # ── Generate test cases ──

  for tracker <- @trackers, backend <- @backends do
    combo_key = {tracker, backend}

    @tag tracker: tracker, backend: backend
    @tag skip: @combo_skip_reasons[combo_key]
    test "end-to-end #{tracker}+#{backend}" do
      run_e2e(unquote(tracker), unquote(backend))
    end
  end

  # ── Main E2E runner ──

  @agent_runner_defaults [
    max_turns: 20,
    active_states: ["Todo", "In Progress"],
    context_window_tokens: 400_000
  ]

  defp agent_runner_opts(extra_opts) when is_list(extra_opts) do
    @agent_runner_defaults |> Keyword.merge(extra_opts)
  end

  defp run_e2e(tracker, backend) do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-live-e2e-#{tracker}-#{backend}-#{System.unique_integer([:positive])}"
      )

    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    workspace_root = Path.join(test_root, "workspaces")
    backend_command = backend_command(backend)
    original_workflow_path = Workflow.workflow_file_path()

    File.mkdir_p!(workflow_root)

    try do
      Workflow.set_workflow_file_path(workflow_file)

      # Phase 1: bootstrap workflow to fetch tracker metadata
      write_bootstrap_workflow!(workflow_file, tracker, workspace_root, backend_command)

      # Phase 2: setup tracker context (create project/issue)
      ctx = setup_tracker_context!(tracker)

      # Phase 3: write final workflow with correct project + runtime
      write_final_workflow!(workflow_file, tracker, ctx, workspace_root, backend, backend_command)

      # Phase 4: run the agent
      assert :ok = AgentRunner.run(ctx.issue, nil, agent_runner_opts(max_turns: 1))

      # Phase 5: verify outcomes
      verify_completion!(tracker, ctx)
    after
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf(test_root)
      cleanup_tracker_context(tracker, Process.get(:e2e_cleanup_ctx))
    end
  end

  # ── Bootstrap workflow ──

  defp write_bootstrap_workflow!(workflow_file, :linear, workspace_root, backend_command) do
    write_workflow_file!(workflow_file,
      tracker_api_token: "$LINEAR_API_KEY",
      tracker_project_slug: "bootstrap",
      workspace_root: workspace_root,
      codex_command: backend_command,
      codex_approval_policy: "never",
      observability_enabled: false
    )
  end

  defp write_bootstrap_workflow!(workflow_file, :plane, workspace_root, backend_command) do
    write_workflow_file!(workflow_file,
      tracker_kind: "plane",
      tracker_endpoint: plane_base_url(),
      tracker_api_token: "$PLANE_API_KEY",
      tracker_workspace_slug: plane_workspace_slug(),
      tracker_project_id: plane_project_id(),
      workspace_root: workspace_root,
      codex_command: backend_command,
      codex_approval_policy: "never",
      observability_enabled: false
    )
  end

  # ── Final workflow ──

  defp write_final_workflow!(workflow_file, :linear, ctx, workspace_root, backend, backend_command) do
    write_workflow_file!(workflow_file,
      tracker_api_token: "$LINEAR_API_KEY",
      tracker_project_slug: ctx.project_slug,
      tracker_active_states: [ctx.active_state_name],
      tracker_terminal_states: ctx.terminal_state_names,
      workspace_root: workspace_root,
      runtimes: [backend_runtime(backend, backend_command)],
      observability_enabled: false,
      prompt: linear_prompt(ctx, backend)
    )
  end

  defp write_final_workflow!(workflow_file, :plane, ctx, workspace_root, backend, backend_command) do
    write_workflow_file!(workflow_file,
      tracker_kind: "plane",
      tracker_endpoint: plane_base_url(),
      tracker_api_token: "$PLANE_API_KEY",
      tracker_workspace_slug: plane_workspace_slug(),
      tracker_project_id: plane_project_id(),
      tracker_active_states: [ctx.active_state_name],
      tracker_terminal_states: ctx.terminal_state_names,
      workspace_root: workspace_root,
      runtimes: [backend_runtime(backend, backend_command)],
      observability_enabled: false,
      prompt: plane_prompt(ctx, backend)
    )
  end

  # ── Tracker context setup ──

  defp setup_tracker_context!(:linear) do
    team_key = System.get_env("SYMPHONY_LIVE_LINEAR_TEAM_KEY") || @default_linear_team_key
    team = linear_fetch_team!(team_key)
    active_state = linear_active_state!(team)
    completed_project_status = linear_completed_project_status!()
    terminal_states = linear_terminal_state_names(team)

    project =
      linear_create_project!(
        team["id"],
        "Symphony E2E #{System.unique_integer([:positive])}"
      )

    issue =
      linear_create_issue!(
        team["id"],
        project["id"],
        active_state["id"],
        "Symphony E2E issue for #{project["name"]}"
      )

    ctx = %{
      project_id: project["id"],
      project_slug: project["slugId"],
      active_state_name: active_state["name"],
      terminal_state_names: terminal_states,
      completed_project_status_id: completed_project_status["id"],
      issue: issue
    }

    Process.put(:e2e_cleanup_ctx, {:linear, ctx})
    ctx
  end

  defp setup_tracker_context!(:plane) do
    {:ok, states} = plane_list_states!()
    active_state = plane_active_state!(states)
    terminal_states = plane_terminal_state_names(states)
    done_state = plane_done_state!(states)

    issue = plane_create_issue!(active_state["id"], "Symphony E2E Plane issue #{System.unique_integer([:positive])}")

    ctx = %{
      active_state_name: active_state["name"],
      terminal_state_names: terminal_states,
      done_state_id: done_state["id"],
      issue: issue
    }

    Process.put(:e2e_cleanup_ctx, {:plane, ctx})
    ctx
  end

  # ── Verification ──

  defp verify_completion!(:linear, ctx) do
    snapshot = linear_fetch_issue_details!(ctx.issue.id)
    assert linear_issue_completed?(snapshot), "expected Linear issue to be in completed state"

    assert linear_issue_has_comment?(snapshot, expected_comment(ctx.issue.identifier, ctx.project_slug, :linear)),
           "expected Linear comment body to match"
  end

  defp verify_completion!(:plane, ctx) do
    {:ok, issue_data} = plane_get_issue!(ctx.issue.id)

    # state_detail may or may not be expanded; fall back to state UUID lookup
    state_name =
      case get_in(issue_data, ["state_detail", "name"]) do
        name when is_binary(name) ->
          name

        _ ->
          state_id = issue_data["state"]

          if is_binary(state_id) do
            {:ok, states} = plane_list_states!()
            state = Enum.find(states, &(&1["id"] == state_id))
            state && state["name"]
          end
      end

    assert state_name in ctx.terminal_state_names,
           "expected Plane issue state #{inspect(state_name)} to be terminal, got issue: #{inspect(Map.take(issue_data, ["state", "state_detail"]))}"

    {:ok, comments} = plane_list_comments!(ctx.issue.id)

    assert Enum.any?(comments, fn c ->
             body = strip_html(c["comment_html"] || "")
             body == expected_comment(ctx.issue.identifier, "plane", :plane)
           end),
           "expected Plane comment body to match"
  end

  # ── Cleanup ──

  defp cleanup_tracker_context(:linear, {:linear, ctx}) do
    linear_complete_project(ctx.project_id, ctx.completed_project_status_id)
  end

  defp cleanup_tracker_context(:plane, {:plane, _ctx}) do
    # Plane issues are already moved to terminal state by the agent
    :ok
  end

  defp cleanup_tracker_context(_tracker, _ctx), do: :ok

  # ════════════════════════════════════════════════
  # LINEAR helpers
  # ════════════════════════════════════════════════

  @linear_team_query """
  query SymphonyLiveE2ETeam($key: String!) {
    teams(filter: {key: {eq: $key}}, first: 1) {
      nodes {
        id
        key
        name
        states(first: 50) {
          nodes {
            id
            name
            type
          }
        }
      }
    }
  }
  """

  @linear_create_project_mutation """
  mutation SymphonyLiveE2ECreateProject($name: String!, $teamIds: [String!]!) {
    projectCreate(input: {name: $name, teamIds: $teamIds}) {
      success
      project {
        id
        name
        slugId
        url
      }
    }
  }
  """

  @linear_create_issue_mutation """
  mutation SymphonyLiveE2ECreateIssue(
    $teamId: String!
    $projectId: String!
    $title: String!
    $description: String!
    $stateId: String
  ) {
    issueCreate(
      input: {
        teamId: $teamId
        projectId: $projectId
        title: $title
        description: $description
        stateId: $stateId
      }
    ) {
      success
      issue {
        id
        identifier
        title
        description
        url
        state {
          name
        }
      }
    }
  }
  """

  @linear_project_statuses_query """
  query SymphonyLiveE2EProjectStatuses {
    projectStatuses(first: 50) {
      nodes {
        id
        name
        type
      }
    }
  }
  """

  @linear_issue_details_query """
  query SymphonyLiveE2EIssueDetails($id: String!) {
    issue(id: $id) {
      id
      identifier
      state {
        name
        type
      }
      comments(first: 20) {
        nodes {
          body
        }
      }
    }
  }
  """

  @linear_complete_project_mutation """
  mutation SymphonyLiveE2ECompleteProject($id: String!, $statusId: String!, $completedAt: DateTime!) {
    projectUpdate(id: $id, input: {statusId: $statusId, completedAt: $completedAt}) {
      success
    }
  }
  """

  defp linear_fetch_team!(team_key) do
    @linear_team_query
    |> linear_graphql_data!(%{key: team_key})
    |> get_in(["teams", "nodes"])
    |> case do
      [team | _] -> team
      _ -> flunk("expected Linear team #{inspect(team_key)} to exist")
    end
  end

  defp linear_active_state!(%{"states" => %{"nodes" => states}}) when is_list(states) do
    Enum.find(states, &(&1["type"] == "started")) ||
      Enum.find(states, &(&1["type"] == "unstarted")) ||
      Enum.find(states, &(&1["type"] not in ["completed", "canceled"])) ||
      flunk("expected team to have at least one non-terminal workflow state")
  end

  defp linear_terminal_state_names(%{"states" => %{"nodes" => states}}) when is_list(states) do
    states
    |> Enum.filter(&(&1["type"] in ["completed", "canceled"]))
    |> Enum.map(& &1["name"])
    |> case do
      [] -> ["Done", "Canceled", "Cancelled"]
      names -> names
    end
  end

  defp linear_completed_project_status! do
    @linear_project_statuses_query
    |> linear_graphql_data!(%{})
    |> get_in(["projectStatuses", "nodes"])
    |> case do
      statuses when is_list(statuses) ->
        Enum.find(statuses, &(&1["type"] == "completed")) ||
          flunk("expected workspace to have a completed project status")

      payload ->
        flunk("expected project statuses list, got: #{inspect(payload)}")
    end
  end

  defp linear_create_project!(team_id, name) do
    @linear_create_project_mutation
    |> linear_graphql_data!(%{teamIds: [team_id], name: name})
    |> linear_fetch_successful_entity!("projectCreate", "project")
  end

  defp linear_create_issue!(team_id, project_id, state_id, title) do
    issue =
      @linear_create_issue_mutation
      |> linear_graphql_data!(%{
        teamId: team_id,
        projectId: project_id,
        title: title,
        description: title,
        stateId: state_id
      })
      |> linear_fetch_successful_entity!("issueCreate", "issue")

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      state: get_in(issue, ["state", "name"]),
      url: issue["url"],
      labels: [],
      blocked_by: []
    }
  end

  defp linear_fetch_issue_details!(issue_id) when is_binary(issue_id) do
    @linear_issue_details_query
    |> linear_graphql_data!(%{id: issue_id})
    |> get_in(["issue"])
    |> case do
      %{} = issue -> issue
      payload -> flunk("expected issue details, got: #{inspect(payload)}")
    end
  end

  defp linear_issue_completed?(%{"state" => %{"type" => type}}), do: type in ["completed", "canceled"]
  defp linear_issue_completed?(_), do: false

  defp linear_issue_has_comment?(%{"comments" => %{"nodes" => comments}}, expected) when is_list(comments) do
    Enum.any?(comments, &(&1["body"] == expected))
  end

  defp linear_issue_has_comment?(_, _), do: false

  defp linear_complete_project(project_id, completed_status_id)
       when is_binary(project_id) and is_binary(completed_status_id) do
    case Client.graphql(@linear_complete_project_mutation, %{
           id: project_id,
           statusId: completed_status_id,
           completedAt: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
         }) do
      {:ok, %{"data" => %{"projectUpdate" => %{"success" => true}}}} -> :ok
      other -> Logger.warning("Linear project cleanup: #{inspect(other)}")
    end

    :ok
  end

  defp linear_graphql_data!(query, variables) when is_binary(query) and is_map(variables) do
    case Client.graphql(query, variables) do
      {:ok, %{"data" => data, "errors" => errors}} when is_map(data) and is_list(errors) ->
        flunk("Linear GraphQL returned partial errors: #{inspect(errors)}")

      {:ok, %{"errors" => errors}} when is_list(errors) ->
        flunk("Linear GraphQL failed: #{inspect(errors)}")

      {:ok, %{"data" => data}} when is_map(data) ->
        data

      {:ok, payload} ->
        flunk("Linear GraphQL unexpected payload: #{inspect(payload)}")

      {:error, reason} ->
        flunk("Linear GraphQL request failed: #{inspect(reason)}")
    end
  end

  defp linear_fetch_successful_entity!(data, mutation_name, entity_name) do
    case data do
      %{^mutation_name => %{"success" => true, ^entity_name => %{} = entity}} ->
        entity

      _ ->
        flunk("expected successful #{mutation_name}, got: #{inspect(data)}")
    end
  end

  # ════════════════════════════════════════════════
  # PLANE helpers
  # ════════════════════════════════════════════════

  alias SymphonyElixir.Plane.Client, as: PlaneClient

  defp plane_list_states! do
    case PlaneClient.list_states() do
      {:ok, states} -> {:ok, states}
      {:error, reason} -> flunk("Plane list_states failed: #{inspect(reason)}")
    end
  end

  defp plane_active_state!(states) do
    Enum.find(states, &(&1["name"] == "In Progress")) ||
      Enum.find(states, &(&1["name"] == "Todo")) ||
      Enum.find(states, fn s -> s["group"] not in ["completed", "cancelled"] end) ||
      flunk("expected Plane project to have an active state")
  end

  defp plane_done_state!(states) do
    Enum.find(states, &(&1["name"] == "Done")) ||
      Enum.find(states, fn s -> s["group"] == "completed" end) ||
      flunk("expected Plane project to have a completed state")
  end

  defp plane_terminal_state_names(states) do
    states
    |> Enum.filter(fn s -> s["group"] in ["completed", "cancelled"] end)
    |> Enum.map(& &1["name"])
    |> case do
      [] -> ["Done", "Cancelled"]
      names -> names
    end
  end

  defp plane_create_issue!(state_id, title) do
    case PlaneClient.create_issue(%{
           "name" => title,
           "description_html" => "<p>#{title}</p>",
           "state" => state_id
         }) do
      {:ok, data} ->
        normalized = plane_normalize_issue(data)
        normalized

      {:error, reason} ->
        flunk("Plane create_issue failed: #{inspect(reason)}")
    end
  end

  defp plane_get_issue!(issue_id) do
    case PlaneClient.get_issue(issue_id) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> flunk("Plane get_issue failed: #{inspect(reason)}")
    end
  end

  defp plane_list_comments!(issue_id) do
    tracker = Config.settings!().tracker

    path =
      "/api/v1/workspaces/#{tracker.workspace_slug}/projects/#{tracker.project_id}/issues/#{issue_id}/comments/"

    case plane_api_get(path) do
      {:ok, %{"results" => results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, reason} -> flunk("Plane list_comments failed: #{inspect(reason)}")
    end
  end

  defp plane_api_get(path) do
    tracker = Config.settings!().tracker
    url = tracker.endpoint <> path

    case Req.get(url,
           headers: [{"x-api-key", tracker.api_key}, {"Content-Type", "application/json"}],
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:plane_api_status, status}}
      {:error, reason} -> {:error, {:plane_api_request, reason}}
    end
  end

  defp plane_normalize_issue(data) do
    tracker = Config.settings!().tracker
    sequence_id = data["sequence_id"]
    identifier = if sequence_id, do: "#{tracker.project_slug || "PLANE"}-#{sequence_id}", else: data["id"]

    %Issue{
      id: data["id"],
      identifier: identifier,
      title: data["name"],
      description: data["description_html"] || data["description"],
      state: get_in(data, ["state_detail", "name"]),
      url: "#{tracker.endpoint}/#{tracker.workspace_slug}/projects/#{tracker.project_id}/issues/#{data["id"]}",
      labels: [],
      blocked_by: []
    }
  end

  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp strip_html(_), do: ""

  # ════════════════════════════════════════════════
  # Shared helpers
  # ════════════════════════════════════════════════

  defp expected_comment(issue_identifier, project_slug, tracker) do
    "Symphony live e2e comment\nidentifier=#{issue_identifier}\nproject_slug=#{project_slug}\ntracker=#{tracker}"
  end

  defp backend_command(:codex), do: System.get_env("SYMPHONY_LIVE_CODEX_COMMAND") || "codex app-server"
  defp backend_command(:opencode), do: System.get_env("SYMPHONY_LIVE_OPENCODE_COMMAND") || "opencode acp"
  defp backend_command(:claude), do: System.get_env("SYMPHONY_LIVE_CLAUDE_COMMAND") || "claude"

  defp backend_runtime(backend, command) do
    %{
      name: "default",
      provider: to_string(backend),
      command: command,
      approval_policy: "never",
      turn_timeout_ms: 600_000
    }
  end

  defp plane_base_url, do: System.get_env("PLANE_BASE_URL") || @default_plane_base_url
  defp plane_workspace_slug, do: System.get_env("PLANE_WORKSPACE_SLUG") || @default_plane_workspace_slug
  defp plane_project_id, do: System.get_env("PLANE_PROJECT_ID") || @default_plane_project_id

  # ── Prompts ──

  defp linear_prompt(ctx, backend) do
    """
    You are running a real Symphony end-to-end test for Linear+#{backend}.

    The current working directory is the workspace root.

    Step 1:
    Use the `linear_graphql` tool to query the current issue by `{{ issue.id }}` and read:
    - existing comments
    - team workflow states

    If the exact comment body below is not already present, post exactly one comment on the current issue with this exact body:
    #{expected_comment("{{ issue.identifier }}", ctx.project_slug, :linear)}

    Use these exact GraphQL operations:

    ```graphql
    query IssueContext($id: String!) {
      issue(id: $id) {
        comments(first: 20) {
          nodes {
            body
          }
        }
        team {
          states(first: 50) {
            nodes {
              id
              name
              type
            }
          }
        }
      }
    }
    ```

    ```graphql
    mutation AddComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) {
        success
      }
    }
    ```

    Step 2:
    Use the same issue-context query result to choose a workflow state whose `type` is `completed`.
    Then move the current issue to that state with this exact mutation:

    ```graphql
    mutation CompleteIssue($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: {stateId: $stateId}) {
        success
      }
    }
    ```

    Step 3:
    Verify all outcomes with one final `linear_graphql` query against `{{ issue.id }}`:
    - the exact comment body is present
    - the issue state type is `completed`

    Do not ask for approval and do not stop early.
    Stop only after both conditions are true:
    1. the Linear comment exists with the exact body above
    2. the Linear issue is in a completed terminal state
    """
  end

  defp plane_prompt(_ctx, backend) do
    """
    You are running a real Symphony end-to-end test for Plane+#{backend}.

    The current working directory is the workspace root.

    Step 1:
    Use the `tracker_api` tool to list the current issue details.
    Call `tracker_api` with operation `get_issue` and params `{"issue_id": "{{ issue.id }}"}`.
    Also call `tracker_api` with operation `list_states` to get all workflow states.

    Step 2:
    If the exact comment body below is not already present, post exactly one comment:
    Call `tracker_api` with operation `create_comment` and params:
    `{"issue_id": "{{ issue.id }}", "body": "#{expected_comment("{{ issue.identifier }}", "plane", :plane)}"}`

    Step 3:
    From the states list, find the state named "Done" (or any state in the "completed" group).
    Move the issue to that state:
    Call `tracker_api` with operation `update_state` and params:
    `{"issue_id": "{{ issue.id }}", "state": "Done"}`

    If "Done" does not exist, use any terminal/completed state from the list.

    Step 4:
    Verify by calling `tracker_api` with operation `get_issue` and params `{"issue_id": "{{ issue.id }}"}`.
    Confirm:
    1. the issue state is in a completed/terminal state
    2. the comment was posted

    Do not ask for approval and do not stop early.
    Stop only after both conditions are verified.
    """
  end
end
