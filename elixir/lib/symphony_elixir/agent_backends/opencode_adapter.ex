defmodule SymphonyElixir.AgentBackends.OpenCodeAdapter do
  @moduledoc false

  @doc "Normalize a raw OpenCode event into canonical form."
  @spec normalize_event(map()) :: {:ok, map()} | :ignore | {:error, term()}
  def normalize_event(%{"event" => "session.started"}) do
    {:ok, %{event: :session_started, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"event" => "turn.started"}) do
    {:ok, %{event: :turn_started, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"event" => "message.delta"} = payload) do
    {:ok, %{event: :message_delta, message: read_message(payload), tool: nil, status: :ok}}
  end

  def normalize_event(%{"event" => "tool.call"} = payload) do
    {:ok, %{event: :tool_call, message: nil, tool: read_tool_name(payload), status: :ok}}
  end

  def normalize_event(%{"event" => "turn.completed"}) do
    {:ok, %{event: :turn_completed, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"event" => "turn.failed"} = payload) do
    {:ok, %{event: :turn_failed, message: inspect(payload), tool: nil, status: :error}}
  end

  def normalize_event(%{}), do: :ignore
  def normalize_event(other), do: {:error, {:invalid_event, other}}

  defp read_message(payload) do
    case Map.get(payload, "text") do
      value when is_binary(value) -> value
      _ -> ""
    end
  end

  defp read_tool_name(payload) do
    case Map.get(payload, "name") do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
