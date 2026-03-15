defmodule SymphonyElixir.DynamicTools.MCPServerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.DynamicTools.MCPServer

  test "stdio MCP server responds to initialize and tools/list with framed JSON-RPC payloads" do
    input =
      [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2024-11-05"}
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => %{}
        }
      ]
      |> encode_frames()

    responses = run_server_with_input(input)

    assert [%{"id" => 1, "result" => initialize_result}, %{"id" => 2, "result" => tools_list_result}] = responses

    assert initialize_result["protocolVersion"] == "2024-11-05"
    assert initialize_result["serverInfo"]["name"] == "symphony-dynamic-tools"
    assert initialize_result["capabilities"] == %{"tools" => %{}}

    tools = tools_list_result["tools"]
    tool_names = Enum.map(tools, & &1["name"])

    assert Enum.sort(tool_names) == ["linear_graphql", "sync_workpad"]

    linear_graphql = Enum.find(tools, &(&1["name"] == "linear_graphql"))
    sync_workpad = Enum.find(tools, &(&1["name"] == "sync_workpad"))

    assert linear_graphql["inputSchema"]["required"] == ["query"]
    assert sync_workpad["inputSchema"]["required"] == ["issue_id", "file_path"]
  end

  test "stdio MCP server also accepts line-delimited JSON-RPC input" do
    input =
      [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{"protocolVersion" => "2025-11-25"}
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/list",
          "params" => %{}
        }
      ]
      |> encode_lines()

    responses = run_server_with_input(input)

    assert [%{"id" => 1, "result" => initialize_result}, %{"id" => 2, "result" => tools_list_result}] = responses
    assert initialize_result["protocolVersion"] == "2025-11-25"
    assert Enum.sort(Enum.map(tools_list_result["tools"], & &1["name"])) == ["linear_graphql", "sync_workpad"]
  end

  test "tools/call delegates linear_graphql and returns MCP call-tool result" do
    test_pid = self()

    input =
      [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{}
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 2,
          "method" => "tools/call",
          "params" => %{
            "name" => "linear_graphql",
            "arguments" => %{
              "query" => "query Viewer { viewer { id } }",
              "variables" => %{"includeTeams" => false}
            }
          }
        }
      ]
      |> encode_frames()

    responses =
      run_server_with_input(input,
        linear_client: fn query, variables, _opts ->
          send(test_pid, {:linear_client_called, query, variables})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}}

    assert [%{"id" => 1}, %{"id" => 2, "result" => call_result}] = responses
    assert call_result["isError"] == false
    assert [%{"type" => "text", "text" => text}] = call_result["content"]
    assert Jason.decode!(text) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
  end

  test "tools/call returns MCP isError for sync_workpad failures" do
    missing_file =
      Path.join(
        System.tmp_dir!(),
        "missing_workpad_#{System.unique_integer([:positive])}.md"
      )

    input =
      [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{}
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "sync_workpad",
            "arguments" => %{
              "issue_id" => "ENG-42",
              "file_path" => missing_file
            }
          }
        }
      ]
      |> encode_frames()

    responses =
      run_server_with_input(input,
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called when sync_workpad input file cannot be read")
        end
      )

    assert [%{"id" => 1}, %{"id" => 3, "result" => call_result}] = responses
    assert call_result["isError"] == true
    assert [%{"type" => "text", "text" => text}] = call_result["content"]
    assert Jason.decode!(text)["error"]["message"] =~ "cannot read"
  end

  test "unknown methods return JSON-RPC method-not-found errors" do
    input =
      [
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{}
        },
        %{
          "jsonrpc" => "2.0",
          "id" => 99,
          "method" => "unknown/method",
          "params" => %{}
        }
      ]
      |> encode_frames()

    responses = run_server_with_input(input)

    assert [%{"id" => 1}, %{"id" => 99, "error" => error}] = responses
    assert error["code"] == -32601
    assert error["message"] == "Method not found"
  end

  defp run_server_with_input(input_frames, opts \\ []) do
    {:ok, input_device} = StringIO.open(input_frames)
    {:ok, output_device} = StringIO.open("")

    assert :ok = MCPServer.serve(opts, input: input_device, output: output_device)

    {_input_echo, output_payload} = StringIO.contents(output_device)
    decode_output_payload(output_payload)
  end

  defp encode_frames(messages) when is_list(messages) do
    Enum.map_join(messages, &encode_frame/1)
  end

  defp encode_frame(message) do
    payload = Jason.encode!(message)
    "Content-Length: #{byte_size(payload)}\r\n\r\n" <> payload
  end

  defp encode_lines(messages) when is_list(messages) do
    Enum.map_join(messages, &(Jason.encode!(&1) <> "\n"))
  end

  defp decode_frames(payload), do: decode_frames(payload, [])

  defp decode_frames("", acc), do: Enum.reverse(acc)

  defp decode_frames(payload, acc) do
    case String.split(payload, "\r\n\r\n", parts: 2) do
      [<<"Content-Length: ", length::binary>>, rest] ->
        {frame_length, ""} = Integer.parse(length)
        <<json::binary-size(frame_length), tail::binary>> = rest
        decode_frames(tail, [Jason.decode!(json) | acc])

      _ ->
        flunk("Invalid MCP frame stream: #{inspect(payload)}")
    end
  end

  defp decode_output_payload(""), do: []

  defp decode_output_payload(payload) when is_binary(payload) do
    trimmed = String.trim_leading(payload)

    if String.starts_with?(trimmed, "Content-Length:") do
      decode_frames(payload)
    else
      payload
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
    end
  end
end
