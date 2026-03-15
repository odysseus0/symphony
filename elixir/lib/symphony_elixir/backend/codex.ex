defmodule SymphonyElixir.Backend.Codex do
  @moduledoc """
  Codex backend adapter implementing `SymphonyElixir.AgentBackend`.

  This module preserves the existing `Codex.AppServer` runtime behavior while
  standardizing emitted callback events as `%{event, timestamp, payload}`.
  """

  @behaviour SymphonyElixir.AgentBackend

  alias SymphonyElixir.Codex.AppServer

  @type session :: AppServer.session()

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @impl true
  @spec start_session(Path.t()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace) do
    AppServer.start_session(workspace)
  end

  @impl true
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    wrapped_opts =
      Keyword.put(opts, :on_message, fn message ->
        on_message.(to_standard_event(message))
      end)

    AppServer.run_turn(session, prompt, issue, wrapped_opts)
  end

  @impl true
  @spec stop_session(session()) :: :ok
  def stop_session(session) do
    AppServer.stop_session(session)
  end

  defp to_standard_event(%{event: event, timestamp: %DateTime{} = timestamp} = message)
       when is_atom(event) do
    %{
      event: event,
      timestamp: timestamp,
      payload: message |> Map.drop([:event, :timestamp]) |> ensure_map_payload()
    }
  end

  defp to_standard_event(%{event: event} = message) when is_atom(event) do
    %{
      event: event,
      timestamp: DateTime.utc_now(),
      payload: message |> Map.drop([:event, :timestamp]) |> ensure_map_payload()
    }
  end

  defp to_standard_event(message) do
    %{
      event: :notification,
      timestamp: DateTime.utc_now(),
      payload: ensure_map_payload(message)
    }
  end

  defp ensure_map_payload(payload) when is_map(payload), do: payload
  defp ensure_map_payload(payload), do: %{message: payload}

  defp default_on_message(_message), do: :ok
end
