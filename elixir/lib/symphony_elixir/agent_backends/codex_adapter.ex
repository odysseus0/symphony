defmodule SymphonyElixir.AgentBackends.CodexAdapter do
  @moduledoc false

  @doc "Normalize a raw Codex JSON-RPC event into canonical form."
  @spec normalize_event(map()) :: {:ok, map()} | :ignore | {:error, term()}
  def normalize_event(%{"method" => "thread/started"}) do
    {:ok, %{event: :session_started, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"method" => "turn/started"}) do
    {:ok, %{event: :turn_started, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"method" => "item/agentMessage/delta", "params" => params}) when is_map(params) do
    {:ok,
     %{event: :message_delta, message: read_message(params, ["delta", "text"]), tool: nil, status: :ok}}
  end

  def normalize_event(%{"method" => "item/tool/call", "params" => params}) when is_map(params) do
    {:ok,
     %{event: :tool_call, message: nil, tool: read_tool_name(params, ["tool", "name"]), status: :ok}}
  end

  def normalize_event(%{"method" => "turn/completed"}) do
    {:ok, %{event: :turn_completed, message: nil, tool: nil, status: :ok}}
  end

  def normalize_event(%{"method" => "turn/failed", "params" => params}) when is_map(params) do
    {:ok, %{event: :turn_failed, message: inspect(params), tool: nil, status: :error}}
  end

  def normalize_event(%{}), do: :ignore
  def normalize_event(other), do: {:error, {:invalid_event, other}}

  defp read_message(payload, keys) do
    Enum.find_value(keys, "", fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp read_tool_name(payload, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(payload, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end
end
