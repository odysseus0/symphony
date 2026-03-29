defmodule SymphonyElixir.DynamicTools.MCPServer do
  @moduledoc """
  Minimal stdio MCP server that exposes Symphony dynamic tools.
  """

  alias SymphonyElixir.{Codex.DynamicTool, Workflow}

  @default_linear_endpoint "https://api.linear.app/graphql"
  @default_protocol_version "2024-11-05"
  @server_name "symphony-dynamic-tools"
  @server_version "0.1.0"
  @wire_mode_framed :framed
  @wire_mode_line :line

  @type linear_client :: (String.t(), map(), keyword() -> {:ok, map()} | {:error, term()})
  @type wire_mode :: :framed | :line
  @type read_result :: {:ok, map(), wire_mode()} | {:error, term()} | :eof
  @type read_fun :: (iodata() -> read_result())
  @type write_fun :: (iodata(), map(), wire_mode() -> :ok | {:error, term()})

  @spec run_cli([String.t()]) :: :ok | {:error, String.t()}
  def run_cli(args \\ []) do
    case parse_cli_args(args) do
      {:ok, opts} ->
        :ok = maybe_set_workflow_file_path()
        serve(opts)

      {:help, usage} ->
        IO.puts(usage)
        :ok

      {:error, message} ->
        {:error, message}
    end
  end

  @spec main([String.t()]) :: no_return()
  def main(args \\ System.argv()) do
    case run_cli(args) do
      :ok ->
        System.halt(0)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @spec serve(keyword(), keyword()) :: :ok
  def serve(opts \\ [], io_opts \\ []) do
    read = Keyword.get(io_opts, :read_fun, &read_packet/1)
    write = Keyword.get(io_opts, :write_fun, &write_packet/3)
    input = Keyword.get(io_opts, :input, :stdio)
    output = Keyword.get(io_opts, :output, :stdio)

    state = %{
      linear_client: linear_client(opts),
      protocol_version: @default_protocol_version,
      wire_mode: @wire_mode_framed
    }

    loop(state, input, output, read, write)
  end

  defp parse_cli_args(args) do
    case OptionParser.parse(args,
           strict: [help: :boolean, linear_api_key: :string, linear_endpoint: :string]
         ) do
      {opts, [], []} ->
        if opts[:help] do
          {:help, usage_message()}
        else
          {:ok,
           [
             linear_api_key: opts[:linear_api_key],
             linear_endpoint: opts[:linear_endpoint]
           ]}
        end

      _ ->
        {:error, usage_message()}
    end
  end

  defp usage_message do
    "Usage: symphony dynamic-tools-mcp [--linear-api-key <token>] [--linear-endpoint <url>]"
  end

  defp maybe_set_workflow_file_path do
    current_path = Workflow.workflow_file_path()

    if File.regular?(current_path) do
      :ok
    else
      fallback_path =
        [
          Path.expand("elixir/WORKFLOW.md", File.cwd!()),
          script_workflow_path()
        ]
        |> Enum.find(&(&1 && File.regular?(&1)))

      if is_binary(fallback_path) do
        Workflow.set_workflow_file_path(fallback_path)
      else
        :ok
      end
    end
  end

  defp script_workflow_path do
    case :escript.script_name() do
      [] ->
        nil

      script_name when is_list(script_name) ->
        script_name
        |> List.to_string()
        |> script_workflow_path_from_script_name()

      script_name when is_binary(script_name) and script_name != "" ->
        script_workflow_path_from_script_name(script_name)

      _ ->
        nil
    end
  end

  defp script_workflow_path_from_script_name(script_name) when is_binary(script_name) do
    script_name
    |> Path.dirname()
    |> Path.join("../WORKFLOW.md")
    |> Path.expand()
  end

  defp loop(state, input, output, read, write) do
    case read.(input) do
      {:ok, %{"id" => id, "method" => method} = payload, wire_mode} when is_binary(method) ->
        {next_state, response} = handle_request(state, id, method, Map.get(payload, "params"))
        updated_state = %{next_state | wire_mode: wire_mode}
        _ = write.(output, response, wire_mode)
        loop(updated_state, input, output, read, write)

      {:ok, %{"method" => method}, wire_mode} when is_binary(method) ->
        loop(%{state | wire_mode: wire_mode}, input, output, read, write)

      {:ok, _payload, wire_mode} ->
        loop(%{state | wire_mode: wire_mode}, input, output, read, write)

      :eof ->
        :ok

      {:error, reason} ->
        _ =
          write.(
            output,
            %{
              "jsonrpc" => "2.0",
              "id" => nil,
              "error" => %{
                "code" => -32700,
                "message" => "Parse error",
                "data" => %{"reason" => inspect(reason)}
              }
            },
            state.wire_mode
          )

        loop(state, input, output, read, write)
    end
  end

  defp handle_request(state, id, "initialize", params) do
    protocol_version =
      case params do
        %{"protocolVersion" => version} when is_binary(version) and version != "" -> version
        _ -> @default_protocol_version
      end

    result = %{
      "protocolVersion" => protocol_version,
      "serverInfo" => %{
        "name" => @server_name,
        "version" => @server_version
      },
      "capabilities" => %{
        "tools" => %{}
      }
    }

    {
      %{state | protocol_version: protocol_version},
      %{"jsonrpc" => "2.0", "id" => id, "result" => result}
    }
  end

  defp handle_request(state, id, "tools/list", _params) do
    result = %{"tools" => DynamicTool.tool_specs()}
    {state, %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
  end

  defp handle_request(state, id, "tools/call", params) do
    case parse_tool_call_params(params) do
      {:ok, tool_name, arguments} ->
        tool_result =
          DynamicTool.execute(tool_name, arguments, linear_client: state.linear_client)
          |> to_mcp_tool_result()

        {state, %{"jsonrpc" => "2.0", "id" => id, "result" => tool_result}}

      {:error, reason} ->
        {state,
         %{
           "jsonrpc" => "2.0",
           "id" => id,
           "error" => %{
             "code" => -32602,
             "message" => "Invalid params",
             "data" => %{"reason" => reason}
           }
         }}
    end
  end

  defp handle_request(state, id, _unknown_method, _params) do
    {state,
     %{
       "jsonrpc" => "2.0",
       "id" => id,
       "error" => %{
         "code" => -32601,
         "message" => "Method not found"
       }
     }}
  end

  defp parse_tool_call_params(%{} = params) do
    name = Map.get(params, "name") || Map.get(params, "tool")
    arguments = Map.get(params, "arguments", %{})

    cond do
      not is_binary(name) or name == "" ->
        {:error, "`name` is required"}

      not is_map(arguments) ->
        {:error, "`arguments` must be an object"}

      true ->
        {:ok, name, arguments}
    end
  end

  defp parse_tool_call_params(_params), do: {:error, "tool call parameters must be an object"}

  defp to_mcp_tool_result(%{"success" => success} = tool_result) do
    content_items =
      case Map.get(tool_result, "contentItems") do
        items when is_list(items) and items != [] ->
          Enum.map(items, &to_mcp_content_item/1)

        _ ->
          [
            %{
              "type" => "text",
              "text" => Jason.encode!(tool_result, pretty: true)
            }
          ]
      end

    %{
      "content" => content_items,
      "isError" => success != true
    }
  end

  defp to_mcp_tool_result(tool_result) do
    %{
      "content" => [
        %{
          "type" => "text",
          "text" => inspect(tool_result)
        }
      ],
      "isError" => true
    }
  end

  defp to_mcp_content_item(%{"type" => "inputText", "text" => text}) when is_binary(text) do
    %{"type" => "text", "text" => text}
  end

  defp to_mcp_content_item(item) do
    %{"type" => "text", "text" => Jason.encode!(item, pretty: true)}
  end

  defp linear_client(opts) do
    case Keyword.get(opts, :linear_client) do
      linear_client when is_function(linear_client, 3) ->
        linear_client

      _ ->
        linear_endpoint = Keyword.get(opts, :linear_endpoint, @default_linear_endpoint)
        linear_api_key = Keyword.get(opts, :linear_api_key) || SymphonyElixir.Credentials.resolve("LINEAR_API_KEY")

        fn query, variables, _client_opts ->
          post_linear_graphql(query, variables, linear_endpoint, linear_api_key)
        end
    end
  end

  defp post_linear_graphql(_query, _variables, _endpoint, nil), do: {:error, :missing_linear_api_token}

  defp post_linear_graphql(query, variables, endpoint, api_key)
       when is_binary(query) and is_map(variables) and is_binary(endpoint) do
    case Req.post(endpoint,
           headers: [
             {"Authorization", api_key},
             {"Content-Type", "application/json"}
           ],
           json: %{"query" => query, "variables" => variables},
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:linear_api_status, status}}

      {:error, reason} ->
        {:error, {:linear_api_request, reason}}
    end
  end

  @spec read_packet(iodata()) :: read_result()
  def read_packet(input) do
    case IO.binread(input, :line) do
      :eof ->
        :eof

      line when is_binary(line) ->
        first_line = trim_line_endings(line)

        cond do
          first_line == "" ->
            read_packet(input)

          json_payload_line?(first_line) ->
            decode_line_payload(first_line)

          true ->
            with {:ok, headers} <- read_headers(input, %{}, first_line),
                 {:ok, length} <- content_length(headers),
                 {:ok, payload} <- read_payload(input, length),
                 {:ok, decoded} <- Jason.decode(payload) do
              {:ok, decoded, @wire_mode_framed}
            else
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  @spec write_packet(iodata(), map(), wire_mode()) :: :ok
  def write_packet(output, %{} = packet, @wire_mode_line) do
    payload = Jason.encode!(packet)
    _ = IO.binwrite(output, payload <> "\n")
    :ok
  end

  def write_packet(output, %{} = packet, @wire_mode_framed) do
    payload = Jason.encode!(packet)
    _ = IO.binwrite(output, "Content-Length: #{byte_size(payload)}\r\n\r\n")
    _ = IO.binwrite(output, payload)
    :ok
  end

  defp read_headers(input, headers, line \\ nil)

  defp read_headers(input, headers, nil) do
    case IO.binread(input, :line) do
      :eof ->
        if map_size(headers) == 0, do: :eof, else: {:error, :unexpected_eof_in_headers}

      line when is_binary(line) ->
        read_headers(input, headers, trim_line_endings(line))
    end
  end

  defp read_headers(_input, headers, ""), do: {:ok, headers}

  defp read_headers(input, headers, line) do
    case String.split(line, ":", parts: 2) do
      [name, value] ->
        header_name = name |> String.trim() |> String.downcase()
        header_value = String.trim(value)
        read_headers(input, Map.put(headers, header_name, header_value))

      _ ->
        {:error, {:invalid_header, line}}
    end
  end

  defp content_length(headers) when is_map(headers) do
    case Map.get(headers, "content-length") do
      nil ->
        {:error, :missing_content_length}

      value ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> {:ok, length}
          _ -> {:error, {:invalid_content_length, value}}
        end
    end
  end

  defp read_payload(_input, 0), do: {:ok, ""}

  defp read_payload(input, content_length) when is_integer(content_length) and content_length > 0 do
    case IO.binread(input, content_length) do
      :eof ->
        {:error, :unexpected_eof_in_payload}

      payload when is_binary(payload) ->
        if byte_size(payload) == content_length do
          {:ok, payload}
        else
          {:error, :truncated_payload}
        end
    end
  end

  defp trim_line_endings(line) when is_binary(line) do
    line
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end

  defp json_payload_line?(line) when is_binary(line) do
    normalized = String.trim_leading(line)
    String.starts_with?(normalized, "{") or String.starts_with?(normalized, "[")
  end

  defp decode_line_payload(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{} = payload} -> {:ok, payload, @wire_mode_line}
      {:ok, _other} -> {:error, :invalid_jsonrpc_payload}
      {:error, reason} -> {:error, reason}
    end
  end
end
