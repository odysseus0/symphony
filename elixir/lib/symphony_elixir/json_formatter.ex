defmodule SymphonyElixir.JsonFormatter do
  @moduledoc """
  Logger formatter that emits one JSON object per line.
  """

  @behaviour :logger_formatter

  @agent_modules MapSet.new([
                   SymphonyElixir.AgentRunner,
                   SymphonyElixir.Orchestrator,
                   SymphonyElixir.Codex.AppServer,
                   SymphonyElixir.Workspace
                 ])

  @context_fields ~w(issue_id issue_identifier session_id workspace)
  @context_field_atoms [:issue_id, :issue_identifier, :session_id, :workspace]

  @impl true
  @spec check_config(term()) :: :ok | {:error, term()}
  def check_config(config) when is_map(config), do: :ok
  def check_config(config), do: {:error, {:invalid_formatter_config, config}}

  @impl true
  @spec format(map(), map()) :: iodata()
  def format(event, _config) when is_map(event) do
    message = render_message(event)
    context_fields = context_fields(event, message)
    module_atom = module_from_event(event)

    payload =
      %{
        "timestamp" => event_timestamp(event),
        "level" => level_name(event),
        "module" => module_name(module_atom),
        "message" => message
      }
      |> Map.merge(optional_context_fields(module_atom, context_fields))

    encode_payload(payload)
  end

  def format(_event, _config), do: []

  defp render_message(event) do
    event
    |> :logger_formatter.format(%{template: [:msg], single_line: true})
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  rescue
    _ -> ""
  end

  defp event_timestamp(%{meta: %{time: time}}), do: format_timestamp(time)
  defp event_timestamp(_event), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp format_timestamp(time) when is_integer(time) do
    case DateTime.from_unix(time, :microsecond) do
      {:ok, datetime} ->
        DateTime.to_iso8601(datetime)

      _ ->
        case DateTime.from_unix(time, :native) do
          {:ok, datetime} -> DateTime.to_iso8601(datetime)
          _ -> DateTime.utc_now() |> DateTime.to_iso8601()
        end
    end
  end

  defp format_timestamp({{year, month, day}, {hour, minute, second}}) do
    with {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      DateTime.to_iso8601(datetime)
    else
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp format_timestamp({{year, month, day}, {hour, minute, second, microsecond}}) do
    with {:ok, naive} <-
           NaiveDateTime.new(year, month, day, hour, minute, second, {microsecond, 6}),
         {:ok, datetime} <- DateTime.from_naive(naive, "Etc/UTC") do
      DateTime.to_iso8601(datetime)
    else
      _ -> DateTime.utc_now() |> DateTime.to_iso8601()
    end
  end

  defp format_timestamp(_time), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp level_name(%{level: level}) when is_atom(level), do: Atom.to_string(level)
  defp level_name(_event), do: "info"

  defp module_from_event(%{meta: %{mfa: {module, _function, _arity}}}) when is_atom(module),
    do: module

  defp module_from_event(%{meta: %{module: module}}) when is_atom(module), do: module
  defp module_from_event(_event), do: nil

  defp module_name(nil), do: "unknown"

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp module_name(_module), do: "unknown"

  defp context_fields(%{meta: metadata}, message) when is_map(metadata) and is_binary(message) do
    message_fields = message_context_fields(message)

    metadata_fields =
      @context_field_atoms
      |> Enum.zip(@context_fields)
      |> Enum.reduce(%{}, fn {metadata_key, output_key}, acc ->
        case Map.get(metadata, metadata_key) do
          nil ->
            acc

          value ->
            Map.put(acc, output_key, normalize_context_value(value))
        end
      end)

    Map.merge(message_fields, metadata_fields)
  end

  defp context_fields(_event, message) when is_binary(message), do: message_context_fields(message)
  defp context_fields(_event, _message), do: %{}

  defp message_context_fields(message) do
    Enum.reduce(@context_fields, %{}, fn field, acc ->
      case Regex.run(~r/\b#{field}=(\"[^\"]*\"|[^\s]+)/, message) do
        [_, value] ->
          cleaned =
            value
            |> String.trim("\"")
            |> String.trim_trailing(";")
            |> String.trim_trailing(",")

          Map.put(acc, field, cleaned)

        _ ->
          acc
      end
    end)
  end

  defp normalize_context_value(value) when is_binary(value), do: value
  defp normalize_context_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_context_value(value), do: to_string(value)

  defp optional_context_fields(module, context_fields) do
    if agent_log?(module, context_fields) do
      Enum.reduce(@context_fields, %{}, fn field, acc ->
        Map.put(acc, field, Map.get(context_fields, field))
      end)
    else
      context_fields
    end
  end

  defp agent_log?(module, context_fields) do
    MapSet.member?(@agent_modules, module) or
      Map.has_key?(context_fields, "issue_id") or
      Map.has_key?(context_fields, "issue_identifier")
  end

  defp encode_payload(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} ->
        [encoded, "\n"]

      {:error, reason} ->
        fallback_payload = %{
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "error",
          "module" => "SymphonyElixir.JsonFormatter",
          "message" => "Failed to encode log payload",
          "formatter_error" => inspect(reason)
        }

        [Jason.encode!(fallback_payload), "\n"]
    end
  end
end
