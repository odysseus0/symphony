defmodule SymphonyElixir.AgentBackends do
  @moduledoc """
  Backend adapter registry and canonical stream normalization helpers.
  """

  alias SymphonyElixir.AgentBackends.{ClaudeAdapter, CodexAdapter, OpenCodeAdapter}

  @type backend :: :codex | :opencode | :claude

  @backends %{
    codex: CodexAdapter,
    opencode: OpenCodeAdapter,
    claude: ClaudeAdapter
  }

  @spec normalize_stream(backend(), String.t(), [map()]) :: [map()]
  def normalize_stream(backend, issue_id, raw_events) when is_list(raw_events) do
    module = backend_module!(backend)

    raw_events
    |> Enum.reduce([], fn raw_event, acc ->
      case module.normalize_event(raw_event) do
        {:ok, canonical_event} ->
          [
            canonical_event
            |> Map.put(:backend, backend)
            |> Map.put(:issue_id, issue_id)
            |> Map.put(:raw_event, raw_event)
            | acc
          ]

        :ignore ->
          acc

        {:error, reason} ->
          raise ArgumentError,
                "failed to normalize #{inspect(backend)} event #{inspect(raw_event)}: #{inspect(reason)}"
      end
    end)
    |> Enum.reverse()
  end

  @spec backend_module!(backend()) :: module()
  def backend_module!(backend) do
    case Map.fetch(@backends, backend) do
      {:ok, module} -> module
      :error -> raise ArgumentError, "unsupported backend: #{inspect(backend)}"
    end
  end
end
