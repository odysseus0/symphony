defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.

  Delegates to the active Tracker adapter for tool specifications and execution,
  allowing each tracker backend (Linear, Plane, etc.) to provide its own tools.
  """

  alias SymphonyElixir.Tracker

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    Tracker.execute_tool(tool, arguments, opts)
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    Tracker.tool_specs()
  end
end
