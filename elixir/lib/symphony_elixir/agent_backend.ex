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

  @callback start_session(workspace :: Path.t()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @spec resolve(term()) :: {:ok, module()} | {:error, term()}
  def resolve("codex"), do: {:ok, SymphonyElixir.Backend.Codex}
  def resolve("opencode"), do: {:ok, SymphonyElixir.Backend.OpenCode}

  def resolve(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :blank_backend}

      String.downcase(trimmed) == "codex" ->
        {:ok, SymphonyElixir.Backend.Codex}

      String.downcase(trimmed) == "opencode" ->
        {:ok, SymphonyElixir.Backend.OpenCode}

      true ->
        with {:ok, module} <- module_from_string(trimmed),
             :ok <- ensure_backend_behaviour(module) do
          {:ok, module}
        end
    end
  end

  def resolve(module) when is_atom(module) do
    with :ok <- ensure_backend_behaviour(module) do
      {:ok, module}
    end
  end

  def resolve(_value), do: {:error, :invalid_backend}

  defp module_from_string(value) when is_binary(value) do
    module_name =
      if String.starts_with?(value, "Elixir.") do
        value
      else
        "Elixir." <> value
      end

    try do
      module = String.to_existing_atom(module_name)

      if Code.ensure_loaded?(module) do
        {:ok, module}
      else
        {:error, {:unknown_backend_module, value}}
      end
    rescue
      ArgumentError ->
        {:error, {:unknown_backend_module, value}}
    end
  end

  defp ensure_backend_behaviour(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :start_session, 1),
         true <- function_exported?(module, :run_turn, 4),
         true <- function_exported?(module, :stop_session, 1) do
      :ok
    else
      _ -> {:error, {:invalid_backend_module, module}}
    end
  end
end
