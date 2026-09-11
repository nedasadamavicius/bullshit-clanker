defmodule BC.Model.OpenAITest do
  use ExUnit.Case, async: false

  test "wire names are valid in schemas and history and decoded in streamed calls" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    previous = :persistent_term.get({:bc, :config}, nil)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if previous, do: BC.Config.put(previous), else: :persistent_term.erase({:bc, :config})
    end)

    config = %BC.Config{
      api_base: "http://127.0.0.1:#{port}",
      api_key: "test-key",
      model: "test-model",
      provider: :anthropic,
      tree_root: "/unused"
    }

    BC.Config.put(config)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        request = receive_request(socket, "")
        send(parent, {:request, Jason.decode!(request)})

        chunk =
          Jason.encode!(%{
            "choices" => [
              %{
                "delta" => %{
                  "tool_calls" => [
                    %{
                      "index" => 0,
                      "id" => "call_new",
                      "function" => %{"name" => "kb_read", "arguments" => "{}"}
                    }
                  ]
                },
                "finish_reason" => "tool_calls"
              }
            ]
          })

        body = "data: #{chunk}\n\ndata: [DONE]\n\n"

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
      end)

    messages = [
      %{
        role: :assistant,
        content: nil,
        tool_call_id: nil,
        tool_calls: [%{id: "call_old", name: "kb.search", arguments: "{}"}]
      },
      %{role: :tool, content: "[]", tool_call_id: "call_old", tool_calls: nil}
    ]

    assert {:ok, result} =
             BC.Model.OpenAI.chat(messages, [tools: BC.Tools.schemas(config)], fn event ->
               send(parent, {:stream, event})
             end)

    assert [%{name: "kb.read", id: "call_new", arguments: "{}"}] = result.tool_calls
    assert_received {:stream, {:tool_call, %{name: "kb.read"}}}
    assert_received {:request, request}
    names = Enum.map(request["tools"], & &1["function"]["name"])
    assert Enum.all?(names, &Regex.match?(~r/^[a-zA-Z0-9_-]{1,128}$/, &1))
    assert "kb_search" in names
    assert "tamago_build" in names
    assert "propose_patch" in names

    assert get_in(hd(request["messages"]), ["tool_calls", Access.at(0), "function", "name"]) ==
             "kb_search"

    assert Enum.at(request["messages"], 1)["tool_call_id"] == "call_old"
    Task.await(server)
  end

  defp receive_request(socket, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

        if byte_size(body) >= String.to_integer(length) do
          body
        else
          {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
          receive_request(socket, buffer <> data)
        end

      _ ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        receive_request(socket, buffer <> data)
    end
  end
end
