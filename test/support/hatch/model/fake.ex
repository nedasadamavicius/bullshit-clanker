defmodule Hatch.Model.Fake do
  @behaviour Hatch.Model

  defstruct responses: [], messages: [], tools: [], position: 0

  def script(responses) do
    %__MODULE__{responses: responses}
  end

  @impl true
  def chat(messages, opts, stream_callback) do
    config = Application.get_env(:hatch, :fake_model, %__MODULE__{})
    tools = opts[:tools] || []

    # Record the call
    config = %{config | messages: messages, tools: tools}
    Application.put_env(:hatch, :fake_model, config)

    # Emit responses in sequence
    result = emit_responses(config.responses, config.position, stream_callback)

    # Update position
    new_position = config.position + Enum.count(config.responses)
    Application.put_env(:hatch, :fake_model, %{config | position: new_position})

    result
  end

  defp emit_responses([], _position, _callback) do
    {:ok, %{text: "", tool_calls: [], finish_reason: "stop", usage: %{}}}
  end

  defp emit_responses(responses, _position, callback) do
    text_parts = []
    tool_calls = []

    {text_parts, tool_calls} =
      Enum.reduce(responses, {text_parts, tool_calls}, fn
        {:text, text}, {texts, calls} ->
          callback.({:text, text})
          {texts ++ [text], calls}

        {:tool_call, name, args}, {texts, calls} ->
          tool_call = %{
            id:
              "call_#{:crypto.hash(:sha, name <> inspect(args)) |> Base.encode16() |> String.slice(0, 24)}",
            name: name,
            arguments: Jason.encode!(args)
          }

          callback.({:tool_call, tool_call})
          {texts, calls ++ [tool_call]}
      end)

    callback.({:done, %{finish_reason: "stop", usage: %{}}})

    {:ok,
     %{
       text: Enum.join(text_parts),
       tool_calls: tool_calls,
       finish_reason: "stop",
       usage: %{}
     }}
  end
end
