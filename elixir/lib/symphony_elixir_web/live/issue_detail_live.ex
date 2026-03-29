defmodule SymphonyElixirWeb.IssueDetailLive do
  @moduledoc """
  LiveView detail page for a single Symphony issue.

  Shows current running state, token usage, intervene form (between-turn directive),
  and activity timeline stub (wired to ActivityLog in BUB-188).
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def mount(%{"identifier" => identifier}, _session, socket) do
    socket =
      socket
      |> assign(:identifier, identifier)
      |> assign(:issue, load_issue(identifier))
      |> assign(:tokens, load_tokens(identifier))
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    identifier = socket.assigns.identifier

    {:noreply,
     socket
     |> assign(:issue, load_issue(identifier))
     |> assign(:tokens, load_tokens(identifier))
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("intervene", %{"directive" => directive}, socket) do
    trimmed = String.trim(directive)

    if trimmed == "" do
      {:noreply, put_flash(socket, :error, "Directive cannot be empty")}
    else
      # Stub: BUB-189 will wire this to the Intervention module
      {:noreply, put_flash(socket, :info, "Directive queued — takes effect after current turn completes")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              <a href="/">← Operations Dashboard</a>
            </p>
            <h1 class="hero-title">
              <%= @identifier %>
            </h1>
            <%= if is_map(@issue) && @issue[:running] do %>
              <p class="hero-copy">
                <span class={state_badge_class(@issue.running.state)}><%= @issue.running.state %></span>
                · Turn <%= @issue.running.turn_count %> · Runtime <span class="numeric mono"><%= format_runtime(@issue.running.started_at, @now) %></span>
              </p>
            <% end %>
          </div>
        </div>
      </header>

      <%= if msg = live_flash(@flash, :info) do %>
        <div class="flash flash-info" role="alert"><%= msg %></div>
      <% end %>
      <%= if msg = live_flash(@flash, :error) do %>
        <div class="flash flash-error" role="alert"><%= msg %></div>
      <% end %>

      <%= if @issue == :not_found do %>
        <section class="error-card">
          <h2 class="error-title">Issue not active</h2>
          <p class="error-copy"><%= @identifier %> is not currently running or retrying.</p>
        </section>
      <% else %>
        <%= if @issue[:running] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Session</h2>
                <p class="section-copy">Current agent session state.</p>
              </div>
            </div>

            <div class="metric-grid">
              <article class="metric-card">
                <p class="metric-label">Session ID</p>
                <p class="metric-value mono" style="font-size: 0.85rem; word-break: break-all;">
                  <%= @issue.running.session_id || "n/a" %>
                </p>
              </article>

              <article class="metric-card">
                <p class="metric-label">Runtime</p>
                <p class="metric-value numeric"><%= format_runtime(@issue.running.started_at, @now) %></p>
                <p class="metric-detail numeric">Turn <%= @issue.running.turn_count %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label">Tokens (session)</p>
                <p class="metric-value numeric"><%= format_int(get_in(@issue, [:running, :tokens, :total_tokens])) %></p>
                <p class="metric-detail numeric">
                  In <%= format_int(get_in(@issue, [:running, :tokens, :input_tokens])) %>
                  / Out <%= format_int(get_in(@issue, [:running, :tokens, :output_tokens])) %>
                </p>
              </article>

              <article class="metric-card">
                <p class="metric-label">Last event</p>
                <p class="metric-value" style="font-size: 0.9rem;"><%= @issue.running.last_message || to_string(@issue.running.last_event || "n/a") %></p>
              </article>
            </div>
          </section>
        <% end %>

        <%= if @tokens && @tokens[:turns] && @tokens.turns != [] do %>
          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Turn token usage</h2>
                <p class="section-copy">Per-turn token breakdown for the current session.</p>
              </div>
            </div>

            <div class="table-wrap">
              <table class="data-table" style="min-width: 480px;">
                <thead>
                  <tr>
                    <th>Turn</th>
                    <th>Input</th>
                    <th>Output</th>
                    <th>Total</th>
                    <th>Recorded at</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={turn <- @tokens.turns}>
                    <td class="numeric"><%= turn.turn_count %></td>
                    <td class="numeric"><%= format_int(turn.input_tokens) %></td>
                    <td class="numeric"><%= format_int(turn.output_tokens) %></td>
                    <td class="numeric"><%= format_int(turn.total_tokens) %></td>
                    <td class="mono"><%= turn.recorded_at || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        <% end %>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Intervene</h2>
              <p class="section-copy">
                Queue a between-turn operator directive. Takes effect after the current turn completes.
              </p>
            </div>
          </div>

          <.form :let={_f} for={%{}} phx-submit="intervene" class="intervene-form">
            <div class="intervene-field">
              <label class="intervene-label" for="directive">Directive</label>
              <textarea
                id="directive"
                name="directive"
                class="intervene-textarea"
                placeholder="e.g. Stop modifying auth, use middleware instead"
                rows="3"
              ></textarea>
            </div>
            <button type="submit" class="subtle-button">Queue directive</button>
          </.form>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Activity timeline</h2>
              <p class="section-copy">Full event log for this issue (BUB-188 pending).</p>
            </div>
          </div>
          <p class="empty-state">Activity log not yet available.</p>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_issue(identifier) do
    case Presenter.issue_payload(identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> payload
      {:error, :issue_not_found} -> :not_found
    end
  end

  defp load_tokens(identifier) do
    case Presenter.issue_tokens_payload(identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} -> payload
      {:error, :issue_not_found} -> nil
    end
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp state_badge_class(state) do
    base = "state-badge"
    normalized = state |> to_string() |> String.downcase()

    cond do
      String.contains?(normalized, ["progress", "running", "active"]) -> "#{base} state-badge-active"
      String.contains?(normalized, ["blocked", "error", "failed"]) -> "#{base} state-badge-danger"
      String.contains?(normalized, ["todo", "queued", "pending", "retry"]) -> "#{base} state-badge-warning"
      true -> base
    end
  end

  defp format_runtime(%DateTime{} = started_at, %DateTime{} = now) do
    secs = max(DateTime.diff(now, started_at, :second), 0)
    mins = div(secs, 60)
    "#{mins}m #{rem(secs, 60)}s"
  end

  defp format_runtime(started_at, now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> format_runtime(parsed, now)
      _ -> "n/a"
    end
  end

  defp format_runtime(_started_at, _now), do: "n/a"

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"
end
