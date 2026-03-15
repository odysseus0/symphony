defmodule SymphonyElixir.AgentBackends.ClaudeAdapter do
  @moduledoc false

  @doc "Normalize a raw Claude event into canonical form."
  @spec normalize_event(map()) :: {:ok, map()} | :ignore | {:error, term()}
  def normalize_event(%{"type" => "session_started"}) do
    {:ok, %{event: :session_started, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"type" => "turn_started"}) do
    {:ok, %{event: :turn_started, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"type" => "content_delta"} = payload) do
    {:ok, %{event: :message_delta, message: read_message(payload), tool: nil, status: :ok}}
  end

  def normalize_event(%{"type" => "tool_use"} = payload) do
    {:ok, %{event: :tool_call, message: nil, tool: read_tool_name(payload), status: :ok}}
  end

  def normalize_event(%{"type" => "turn_completed"}) do
    {:ok, %{event: :turn_completed, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"type" => "turn_failed"} = payload) do
    {:ok, %{event: :turn_failed, message: inspect(payload), tool: nil, status: :error}}
  end

  def normalize_event(%{}), do: :ignore
  def normalize_event(other), do: {:error, {:invalid_event, other}}

  defp read_message(payload) do
    case Map.get(payload, "delta") do
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
