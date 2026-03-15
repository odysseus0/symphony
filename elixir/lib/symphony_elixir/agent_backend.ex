defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Behaviour contract for backend adapters used by `AgentRunner`.
  """

  @typedoc "Backend-owned opaque session state."
  @opaque session :: map()

  @type event :: %{
          required(:event) => atom(),
          required(:timestamp) => DateTime.t(),
          required(:payload) => map()
        }

  @callback start_session(workspace :: Path.t(), opts :: keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec resolve_provider(String.t()) :: {:ok, module()} | {:error, term()}
  def resolve_provider("codex"), do: {:ok, SymphonyElixir.Backend.Codex}
  def resolve_provider("opencode"), do: {:ok, SymphonyElixir.Backend.OpenCode}
  def resolve_provider("claude"), do: {:ok, SymphonyElixir.Backend.Claude}
  def resolve_provider(other), do: {:error, {:unknown_provider, other}}
end
