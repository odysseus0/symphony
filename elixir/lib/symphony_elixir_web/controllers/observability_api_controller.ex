defmodule SymphonyElixirWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Symphony observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec stats(Conn.t(), map()) :: Conn.t()
  def stats(conn, _params) do
    json(conn, Presenter.stats_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec completed_issues(Conn.t(), map()) :: Conn.t()
  def completed_issues(conn, _params) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    json(conn, %{items: [], generated_at: generated_at})
  end

  @spec issue_activity(Conn.t(), map()) :: Conn.t()
  def issue_activity(conn, %{"id" => id} = params) do
    since = Map.get(params, "since")
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    json(conn, %{issue_identifier: id, items: [], has_more: false, since: since, generated_at: generated_at})
  end

  @spec issue_tokens(Conn.t(), map()) :: Conn.t()
  def issue_tokens(conn, %{"id" => id}) do
    case Presenter.issue_tokens_payload(id, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> json(conn, payload)
      {:error, :issue_not_found} -> error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec issue_intervene(Conn.t(), map()) :: Conn.t()
  def issue_intervene(conn, %{"id" => id} = params) do
    raw = Map.get(params, "directive")

    cond do
      not is_binary(raw) ->
        error_response(conn, 422, "directive_required", "directive must be a non-empty string")

      String.trim(raw) == "" ->
        error_response(conn, 422, "directive_required", "directive must be a non-empty string")

      true ->
        directive = String.trim(raw)
        conn |> put_status(202) |> json(%{issue_identifier: id, status: "queued", directive: directive})
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
