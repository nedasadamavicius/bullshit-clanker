defmodule Hatch.Model.OpenAI do
  @behaviour Hatch.Model
  require Logger

  @impl true
  def chat(messages, opts, stream_callback) do
    config = Hatch.Config.get()
    model = opts[:model] || config.model
    timeout_ms = opts[:timeout_ms] || 180_000
    tools = opts[:tools] || []
    temperature = opts[:temperature] || 1.0
    max_tokens = opts[:max_tokens]

    body =
      build_request_body(messages, model, tools, temperature, max_tokens)

    do_chat(config, body, timeout_ms, stream_callback, 0)
  end

  defp do_chat(config, body, timeout_ms, stream_callback, attempt) do
    case perform_request(config, body, timeout_ms, stream_callback) do
      {:ok, result} ->
        {:ok, result}

      {:error, %{code: code}}
      when code in [:rate_limited, :upstream] and attempt < 2 ->
        backoff_ms = backoff_duration(attempt)
        Process.sleep(backoff_ms)
        do_chat(config, body, timeout_ms, stream_callback, attempt + 1)

      {:error, error} ->
        {:error, error}
    end
  end

  defp backoff_duration(0), do: 1_000 + Enum.random(0..100)
  defp backoff_duration(1), do: 4_000 + Enum.random(0..200)

  defp build_request(config, timeout_ms) do
    Req.new(
      base_url: config.api_base,
      auth: {:bearer, config.api_key},
      redirect: false,
      connect_timeout: 10_000,
      timeout: timeout_ms
    )
  end

  defp build_request_body(messages, model, tools, temperature, max_tokens) do
    body = %{
      "model" => model,
      "messages" => Enum.map(messages, &encode_message/1),
      "stream" => true,
      "stream_options" => %{"include_usage" => true},
      "temperature" => temperature
    }

    body =
      if tools != [] do
        Map.put(body, "tools", tools) |> Map.put("tool_choice", "auto")
      else
        body
      end

    if max_tokens do
      Map.put(body, "max_tokens", max_tokens)
    else
      body
    end
  end

  defp encode_message(%{
         role: role,
         content: content,
         tool_calls: tool_calls,
         tool_call_id: tool_call_id
       }) do
    msg = %{"role" => Atom.to_string(role)}

    msg =
      if content do
        Map.put(msg, "content", content)
      else
        Map.put(msg, "content", nil)
      end

    msg =
      if tool_calls && tool_calls != [] do
        Map.put(msg, "tool_calls", Enum.map(tool_calls, &encode_tool_call/1))
      else
        msg
      end

    if tool_call_id do
      Map.put(msg, "tool_call_id", tool_call_id)
    else
      msg
    end
  end

  defp encode_tool_call(%{id: id, name: name, arguments: arguments}) do
    %{
      "id" => id,
      "type" => "function",
      "function" => %{
        "name" => name,
        "arguments" => arguments
      }
    }
  end

  defp perform_request(config, body, timeout_ms, stream_callback) do
    req = build_request(config, timeout_ms)

    state = %{
      text: "",
      tool_calls: [],
      tool_call_buffer: %{},
      finish_reason: nil,
      usage: %{},
      buffer: "",
      error: nil
    }

    try do
      case Req.post(req,
             url: "/chat/completions",
             json: body,
             into: fn chunk, acc ->
               handle_stream_chunk(chunk, acc, stream_callback)
             end
           ) do
        {:ok, state} ->
          case state.error do
            nil ->
              final_state = emit_buffered_tool_calls(state, stream_callback)

              {:ok,
               %{
                 text: final_state.text,
                 tool_calls: Enum.reverse(final_state.tool_calls),
                 finish_reason: final_state.finish_reason || "stop",
                 usage: final_state.usage
               }}

            error ->
              {:error, error}
          end

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:error, %{code: :timeout, message: "Request timeout"}}

        {:error, %Req.TransportError{reason: reason}} ->
          {:error, %{code: :upstream, message: "Transport error: #{inspect(reason)}"}}

        {:error, exception} ->
          {:error, map_exception(exception)}
      end
    rescue
      e ->
        {:error, %{code: :upstream, message: Exception.message(e)}}
    end
  end

  defp handle_stream_chunk({:status, status}, state, _callback)
       when status >= 400 do
    {:halt, %{state | error: %{code: map_status_error(status), message: "HTTP #{status}"}}}
  end

  defp handle_stream_chunk({:headers, _headers}, state, _callback) do
    {:cont, state}
  end

  defp handle_stream_chunk({:data, data}, state, callback) do
    new_buffer = state.buffer <> data

    {new_state, remaining} = process_sse_chunk(new_buffer, state, callback)

    {:cont, %{new_state | buffer: remaining}}
  end

  defp map_status_error(status) do
    case status do
      401 -> :unauthorized
      403 -> :unauthorized
      404 -> :bad_model
      400 -> :invalid_request
      429 -> :rate_limited
      _ -> :upstream
    end
  end

  defp map_exception(%Req.TransportError{reason: :timeout}),
    do: %{code: :timeout, message: "Timeout"}

  defp map_exception(e), do: %{code: :upstream, message: Exception.message(e)}

  defp process_sse_chunk(buffer, state, callback) do
    lines = String.split(buffer, "\n\n")

    complete_messages =
      if String.ends_with?(buffer, "\n\n") do
        lines
      else
        Enum.drop(lines, -1)
      end

    new_state =
      Enum.reduce(complete_messages, state, fn msg, acc ->
        if String.starts_with?(String.trim(msg), "data: ") do
          process_sse_message(msg, acc, callback)
        else
          acc
        end
      end)

    remaining =
      if String.ends_with?(buffer, "\n\n") do
        ""
      else
        List.last(lines) || ""
      end

    {new_state, remaining}
  end

  defp process_sse_message(msg, state, callback) do
    data_line = String.replace_prefix(String.trim(msg), "data: ", "")

    if data_line == "[DONE]" do
      state
    else
      case Jason.decode(data_line) do
        {:ok, json} ->
          process_stream_chunk(json, state, callback)

        {:error, _} ->
          state
      end
    end
  end

  defp process_stream_chunk(chunk, state, callback) do
    choices = chunk["choices"] || []

    state =
      Enum.reduce(choices, state, fn choice, acc ->
        delta = choice["delta"] || %{}
        finish_reason = choice["finish_reason"]

        acc = if finish_reason, do: %{acc | finish_reason: finish_reason}, else: acc

        # Process text content
        acc =
          if delta["content"] do
            callback.({:text, delta["content"]})
            %{acc | text: acc.text <> delta["content"]}
          else
            acc
          end

        # Process tool calls
        if delta["tool_calls"] do
          Enum.reduce(delta["tool_calls"], acc, fn tool_call_delta, acc2 ->
            process_tool_call_delta(tool_call_delta, acc2)
          end)
        else
          acc
        end
      end)

    # Update usage if present
    if chunk["usage"] do
      %{state | usage: chunk["usage"]}
    else
      state
    end
  end

  defp process_tool_call_delta(delta, state) do
    index = delta["index"] || 0
    buffer = state.tool_call_buffer

    tool_call = Map.get(buffer, index, %{})

    tool_call =
      if delta["id"] do
        Map.put(tool_call, "id", delta["id"])
      else
        tool_call
      end

    tool_call =
      if delta["function"] && delta["function"]["name"] do
        Map.put(tool_call, "name", delta["function"]["name"])
      else
        tool_call
      end

    tool_call =
      if delta["function"] && delta["function"]["arguments"] do
        args = Map.get(tool_call, "arguments", "")
        Map.put(tool_call, "arguments", args <> delta["function"]["arguments"])
      else
        tool_call
      end

    updated_buffer = Map.put(buffer, index, tool_call)

    %{state | tool_call_buffer: updated_buffer}
  end

  defp emit_buffered_tool_calls(state, callback) do
    Enum.sort_by(state.tool_call_buffer, fn {index, _} -> index end)
    |> Enum.reduce(state, fn {_index, call}, acc ->
      tool_call = %{
        id: call["id"],
        name: call["name"],
        arguments: call["arguments"]
      }

      callback.({:tool_call, tool_call})
      %{acc | tool_calls: [tool_call | acc.tool_calls]}
    end)
  end
end
