defmodule SymphonyElixir.Plane.Client do
  @moduledoc """
  HTTP client for the Plane REST API.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    active_states = tracker.active_states

    with {:ok, state_ids} <- resolve_state_ids(active_states),
         {:ok, issues} <- fetch_issues_by_state_ids(state_ids) do
      {:ok, issues}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    with {:ok, state_ids} <- resolve_state_ids(state_names),
         {:ok, issues} <- fetch_issues_by_state_ids(state_ids) do
      {:ok, issues}
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    results =
      Enum.reduce_while(issue_ids, {:ok, []}, fn id, {:ok, acc} ->
        case api_get(issue_path(id)) do
          {:ok, data} -> {:cont, {:ok, [normalize_issue(data) | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case results do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  @spec create_comment(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    api_post(
      issue_path(issue_id) <> "comments/",
      %{"comment_html" => "<p>#{body}</p>"}
    )
  end

  @spec update_comment(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_comment(issue_id, comment_id, body)
      when is_binary(issue_id) and is_binary(comment_id) and is_binary(body) do
    api_patch(
      issue_path(issue_id) <> "comments/#{comment_id}/",
      %{"comment_html" => "<p>#{body}</p>"}
    )
  end

  @spec update_issue(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_issue(issue_id, params) when is_binary(issue_id) and is_map(params) do
    api_patch(issue_path(issue_id), params)
  end

  @spec get_issue(String.t()) :: {:ok, map()} | {:error, term()}
  def get_issue(issue_id) when is_binary(issue_id) do
    api_get(issue_path(issue_id))
  end

  @spec list_states() :: {:ok, [map()]} | {:error, term()}
  def list_states do
    api_get(project_path() <> "states/")
    |> case do
      {:ok, %{"results" => results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_labels() :: {:ok, [map()]} | {:error, term()}
  def list_labels do
    api_get(project_path() <> "labels/")
    |> case do
      {:ok, %{"results" => results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_issue(map()) :: {:ok, map()} | {:error, term()}
  def create_issue(params) when is_map(params) do
    api_post(project_path() <> "issues/", params)
  end

  @spec list_issue_links(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_issue_links(issue_id) when is_binary(issue_id) do
    api_get(issue_path(issue_id) <> "links/")
    |> case do
      {:ok, %{"results" => results}} -> {:ok, results}
      {:ok, results} when is_list(results) -> {:ok, results}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_issue_link(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_issue_link(issue_id, params) when is_binary(issue_id) and is_map(params) do
    api_post(issue_path(issue_id) <> "links/", params)
  end

  @spec create_issue_relation(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def create_issue_relation(issue_id, params) when is_binary(issue_id) and is_map(params) do
    api_post(issue_path(issue_id) <> "relations/", params)
  end

  # Private

  defp resolve_state_ids(state_names) do
    with {:ok, states} <- list_states() do
      name_set = MapSet.new(state_names, &String.downcase/1)

      ids =
        states
        |> Enum.filter(fn s -> MapSet.member?(name_set, String.downcase(s["name"] || "")) end)
        |> Enum.map(& &1["id"])

      {:ok, ids}
    end
  end

  defp fetch_issues_by_state_ids([]), do: {:ok, []}

  defp fetch_issues_by_state_ids(state_ids) do
    query = state_ids |> Enum.map(&"state=#{&1}") |> Enum.join("&")

    case api_get(project_path() <> "issues/?#{query}&per_page=100") do
      {:ok, %{"results" => results}} -> {:ok, Enum.map(results, &normalize_issue/1)}
      {:ok, results} when is_list(results) -> {:ok, Enum.map(results, &normalize_issue/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_issue(data) when is_map(data) do
    %Issue{
      id: data["id"],
      identifier: data["sequence_id"] && "#{project_identifier()}-#{data["sequence_id"]}",
      title: data["name"],
      description: data["description_html"] || data["description"],
      priority: normalize_priority(data["priority"]),
      state: get_in(data, ["state_detail", "name"]) || data["state"],
      branch_name: nil,
      url: build_issue_url(data),
      assignee_id: extract_assignee_id(data),
      blocked_by: [],
      labels: extract_labels(data),
      assigned_to_worker: true,
      created_at: parse_datetime(data["created_at"]),
      updated_at: parse_datetime(data["updated_at"])
    }
  end

  defp normalize_issue(_), do: nil

  defp normalize_priority(nil), do: nil
  defp normalize_priority("urgent"), do: 1
  defp normalize_priority("high"), do: 2
  defp normalize_priority("medium"), do: 3
  defp normalize_priority("low"), do: 4
  defp normalize_priority("none"), do: 0
  defp normalize_priority(p) when is_integer(p), do: p
  defp normalize_priority(_), do: nil

  defp extract_assignee_id(%{"assignees" => [first | _]}) when is_binary(first), do: first
  defp extract_assignee_id(%{"assignees" => [%{"id" => id} | _]}), do: id
  defp extract_assignee_id(_), do: nil

  defp extract_labels(%{"label_detail" => labels}) when is_list(labels) do
    Enum.map(labels, fn l -> String.downcase(l["name"] || "") end)
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    Enum.map(labels, fn
      l when is_map(l) -> String.downcase(l["name"] || "")
      _ -> ""
    end)
  end

  defp extract_labels(_), do: []

  defp build_issue_url(%{"id" => id}) do
    tracker = Config.settings!().tracker
    "#{tracker.endpoint}/#{tracker.workspace_slug}/projects/#{tracker.project_id}/issues/#{id}"
  end

  defp build_issue_url(_), do: nil

  defp project_identifier do
    Config.settings!().tracker.project_slug
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  # HTTP helpers

  defp project_path do
    tracker = Config.settings!().tracker
    "/api/v1/workspaces/#{tracker.workspace_slug}/projects/#{tracker.project_id}/"
  end

  defp issue_path(issue_id) do
    project_path() <> "issues/#{issue_id}/"
  end

  defp api_get(path) do
    with {:ok, headers} <- auth_headers() do
      url = base_url() <> path

      case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          {:ok, body}

        {:ok, %{status: status} = response} ->
          Logger.error("Plane API GET #{path} failed status=#{status}#{error_context(response)}")
          {:error, {:plane_api_status, status}}

        {:error, reason} ->
          Logger.error("Plane API GET #{path} failed: #{inspect(reason)}")
          {:error, {:plane_api_request, reason}}
      end
    end
  end

  defp api_post(path, body) do
    with {:ok, headers} <- auth_headers() do
      url = base_url() <> path

      case Req.post(url, headers: headers, json: body, connect_options: [timeout: 30_000]) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %{status: status} = response} ->
          Logger.error("Plane API POST #{path} failed status=#{status}#{error_context(response)}")
          {:error, {:plane_api_status, status}}

        {:error, reason} ->
          Logger.error("Plane API POST #{path} failed: #{inspect(reason)}")
          {:error, {:plane_api_request, reason}}
      end
    end
  end

  defp api_patch(path, body) do
    with {:ok, headers} <- auth_headers() do
      url = base_url() <> path

      case Req.patch(url, headers: headers, json: body, connect_options: [timeout: 30_000]) do
        {:ok, %{status: status, body: resp_body}} when status in 200..299 ->
          {:ok, resp_body}

        {:ok, %{status: status} = response} ->
          Logger.error("Plane API PATCH #{path} failed status=#{status}#{error_context(response)}")
          {:error, {:plane_api_status, status}}

        {:error, reason} ->
          Logger.error("Plane API PATCH #{path} failed: #{inspect(reason)}")
          {:error, {:plane_api_request, reason}}
      end
    end
  end

  defp base_url do
    Config.settings!().tracker.endpoint
  end

  defp auth_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_plane_api_token}

      token ->
        {:ok,
         [
           {"x-api-key", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp error_context(%{body: body}) when is_binary(body) do
    truncated =
      body
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    truncated =
      if byte_size(truncated) > @max_error_body_log_bytes,
        do: binary_part(truncated, 0, @max_error_body_log_bytes) <> "...<truncated>",
        else: truncated

    " body=#{inspect(truncated)}"
  end

  defp error_context(_), do: ""
end
