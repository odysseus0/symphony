defmodule SymphonyElixir.Plane.Adapter do
  @moduledoc """
  Plane-backed tracker adapter.

  Provides both orchestrator-level callbacks (fetch issues, update state, create comments)
  and agent-level dynamic tools (tracker_api, sync_workpad) for Codex.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Plane.Client

  # Dynamic tool definitions

  @tracker_api_tool "tracker_api"
  @tracker_api_description """
  Execute operations against the Plane project management API.
  Supported operations: get_issue, list_issues, update_state, create_comment, update_comment,
  create_issue, link_pr, create_relation, list_states, list_labels.
  """
  @tracker_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["operation"],
    "properties" => %{
      "operation" => %{
        "type" => "string",
        "description" => "The operation to execute.",
        "enum" => [
          "get_issue",
          "list_issues",
          "update_state",
          "create_comment",
          "update_comment",
          "create_issue",
          "link_pr",
          "create_relation",
          "list_states",
          "list_labels"
        ]
      },
      "params" => %{
        "type" => "object",
        "description" => "Operation-specific parameters.",
        "additionalProperties" => true
      }
    }
  }

  @sync_workpad_tool "sync_workpad"
  @sync_workpad_description "Create or update a workpad comment on a Plane issue. Reads the body from a local file to keep the conversation context small."
  @sync_workpad_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "file_path"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "Plane issue UUID."
      },
      "file_path" => %{
        "type" => "string",
        "description" => "Path to a local markdown file whose contents become the comment body."
      },
      "comment_id" => %{
        "type" => "string",
        "description" => "Existing comment ID to update. Omit to create a new comment."
      }
    }
  }

  # Tracker callbacks

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    case client_module().create_comment(issue_id, body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(state_name),
         {:ok, _} <- client_module().update_issue(issue_id, %{"state" => state_id}) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # Dynamic tool callbacks

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @tracker_api_tool,
        "description" => @tracker_api_description,
        "inputSchema" => @tracker_api_input_schema
      },
      %{
        "name" => @sync_workpad_tool,
        "description" => @sync_workpad_description,
        "inputSchema" => @sync_workpad_input_schema
      }
    ]
  end

  @spec execute_tool(String.t(), map(), keyword()) :: map()
  def execute_tool(tool, arguments, opts \\ [])

  def execute_tool(@tracker_api_tool, arguments, _opts) do
    execute_tracker_api(arguments)
  end

  def execute_tool(@sync_workpad_tool, arguments, _opts) do
    execute_sync_workpad(arguments)
  end

  def execute_tool(other, _arguments, _opts) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(other)}.",
        "supportedTools" => [@tracker_api_tool, @sync_workpad_tool]
      }
    })
  end

  # Private — tracker_api operations

  defp execute_tracker_api(%{} = args) do
    operation = Map.get(args, "operation") || Map.get(args, :operation)
    params = Map.get(args, "params") || Map.get(args, :params) || %{}

    case operation do
      "get_issue" -> op_get_issue(params)
      "list_issues" -> op_list_issues(params)
      "update_state" -> op_update_state(params)
      "create_comment" -> op_create_comment(params)
      "update_comment" -> op_update_comment(params)
      "create_issue" -> op_create_issue(params)
      "link_pr" -> op_link_pr(params)
      "create_relation" -> op_create_relation(params)
      "list_states" -> op_list_states()
      "list_labels" -> op_list_labels()
      nil -> failure_response(%{"error" => %{"message" => "`operation` is required."}})
      other -> failure_response(%{"error" => %{"message" => "Unknown operation: #{inspect(other)}."}})
    end
  end

  defp op_get_issue(%{"issue_id" => id}) when is_binary(id) do
    case client_module().get_issue(id) do
      {:ok, data} -> success_response(data)
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_get_issue(_), do: failure_response(%{"error" => %{"message" => "`issue_id` is required."}})

  defp op_list_issues(%{"states" => states}) when is_list(states) do
    case client_module().fetch_issues_by_states(states) do
      {:ok, issues} -> success_response(%{"issues" => Enum.map(issues, &Map.from_struct/1)})
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_list_issues(_) do
    case client_module().fetch_candidate_issues() do
      {:ok, issues} -> success_response(%{"issues" => Enum.map(issues, &Map.from_struct/1)})
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_update_state(%{"issue_id" => id, "state" => state}) when is_binary(id) and is_binary(state) do
    case update_issue_state(id, state) do
      :ok -> success_response(%{"updated" => true})
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_update_state(_), do: failure_response(%{"error" => %{"message" => "`issue_id` and `state` are required."}})

  defp op_create_comment(%{"issue_id" => id, "body" => body}) when is_binary(id) and is_binary(body) do
    case client_module().create_comment(id, body) do
      {:ok, data} -> success_response(data)
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_create_comment(_), do: failure_response(%{"error" => %{"message" => "`issue_id` and `body` are required."}})

  defp op_update_comment(%{"issue_id" => id, "comment_id" => cid, "body" => body})
       when is_binary(id) and is_binary(cid) and is_binary(body) do
    case client_module().update_comment(id, cid, body) do
      {:ok, data} -> success_response(data)
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_update_comment(_) do
    failure_response(%{"error" => %{"message" => "`issue_id`, `comment_id`, and `body` are required."}})
  end

  defp op_create_issue(%{} = params) do
    case client_module().create_issue(params) do
      {:ok, data} -> success_response(data)
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_link_pr(%{"issue_id" => id, "pr_url" => url}) when is_binary(id) and is_binary(url) do
    title = Map.get(%{}, "title", "Pull Request")

    case client_module().create_issue_link(id, %{"url" => url, "title" => title}) do
      {:ok, data} -> success_response(data)
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_link_pr(_), do: failure_response(%{"error" => %{"message" => "`issue_id` and `pr_url` are required."}})

  defp op_create_relation(%{"issue_id" => id, "related_issue_id" => rid, "relation_type" => rtype})
       when is_binary(id) and is_binary(rid) and is_binary(rtype) do
    case client_module().create_issue_relation(id, %{
           "related_issue" => rid,
           "relation_type" => rtype
         }) do
      {:ok, data} -> success_response(data)
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_create_relation(_) do
    failure_response(%{"error" => %{"message" => "`issue_id`, `related_issue_id`, and `relation_type` are required."}})
  end

  defp op_list_states do
    case client_module().list_states() do
      {:ok, states} -> success_response(%{"states" => states})
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp op_list_labels do
    case client_module().list_labels() do
      {:ok, labels} -> success_response(%{"labels" => labels})
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  # Private — sync_workpad

  defp execute_sync_workpad(%{} = args) do
    issue_id = Map.get(args, "issue_id") || Map.get(args, :issue_id)
    file_path = Map.get(args, "file_path") || Map.get(args, :file_path)
    comment_id = Map.get(args, "comment_id") || Map.get(args, :comment_id)

    with :ok <- validate_required_string(issue_id, "issue_id"),
         :ok <- validate_required_string(file_path, "file_path"),
         {:ok, body} <- read_workpad_file(file_path) do
      comment_id = if is_binary(comment_id) and comment_id != "", do: comment_id

      result =
        if comment_id do
          client_module().update_comment(issue_id, comment_id, body)
        else
          client_module().create_comment(issue_id, body)
        end

      case result do
        {:ok, data} -> success_response(data)
        {:error, reason} -> failure_response(error_payload(reason))
      end
    else
      {:error, reason} -> failure_response(error_payload(reason))
    end
  end

  defp execute_sync_workpad(_) do
    failure_response(%{"error" => %{"message" => "`issue_id` and `file_path` are required."}})
  end

  # Private — helpers

  defp resolve_state_id(state_name) do
    with {:ok, states} <- client_module().list_states() do
      target = String.downcase(state_name)

      case Enum.find(states, fn s -> String.downcase(s["name"] || "") == target end) do
        %{"id" => id} -> {:ok, id}
        nil -> {:error, :state_not_found}
      end
    end
  end

  defp validate_required_string(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_required_string(_, field), do: {:error, {:validation, "`#{field}` is required"}}

  defp read_workpad_file(path) do
    case File.read(path) do
      {:ok, ""} -> {:error, {:sync_workpad, "file is empty: `#{path}`"}}
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:sync_workpad, "cannot read `#{path}`: #{:file.format_error(reason)}"}}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :plane_client_module, Client)
  end

  # Private — response formatting

  defp success_response(data) do
    %{
      "success" => true,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(data)
        }
      ]
    }
  end

  defp failure_response(payload) do
    %{
      "success" => false,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => encode_payload(payload)
        }
      ]
    }
  end

  defp error_payload({:sync_workpad, message}), do: %{"error" => %{"message" => "sync_workpad: #{message}"}}
  defp error_payload({:validation, message}), do: %{"error" => %{"message" => message}}
  defp error_payload({:plane_api_status, status}), do: %{"error" => %{"message" => "Plane API failed with HTTP #{status}.", "status" => status}}
  defp error_payload({:plane_api_request, reason}), do: %{"error" => %{"message" => "Plane API request failed.", "reason" => inspect(reason)}}
  defp error_payload(:state_not_found), do: %{"error" => %{"message" => "State not found in Plane project."}}
  defp error_payload(:missing_plane_api_token), do: %{"error" => %{"message" => "Symphony is missing Plane auth. Set `tracker.api_key` in `WORKFLOW.md` or export `PLANE_API_KEY`."}}
  defp error_payload(reason), do: %{"error" => %{"message" => "Plane operation failed.", "reason" => inspect(reason)}}

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)
end
