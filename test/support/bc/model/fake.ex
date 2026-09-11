defmodule BC.Model.Fake do
  @behaviour BC.Model

  defstruct script_turns: [], messages: [], tools: [], turn_index: 0

  def script(response_items) when is_list(response_items) do
    # Wrap single response set into a list of turns
    %__MODULE__{script_turns: [response_items]}
  end

  def script_many(response_turns) when is_list(response_turns) do
    # Multiple turns, each turn is a list of response items
    %__MODULE__{script_turns: response_turns}
  end

  @impl true
  def chat(messages, opts, stream_callback) do
    config = Application.get_env(:bc, :fake_model, %__MODULE__{})
    tools = opts[:tools] || []

    # Record the call
    config = %{config | messages: messages, tools: tools}
    Application.put_env(:bc, :fake_model, config)

    # Get responses for this turn
    current_responses =
      if config.turn_index < length(config.script_turns) do
        Enum.at(config.script_turns, config.turn_index)
      else
        []
      end

    # Emit responses
    result = emit_responses(current_responses, stream_callback)

    # Move to next turn
    new_config = %{config | turn_index: config.turn_index + 1}
    Application.put_env(:bc, :fake_model, new_config)

    result
  end

  defp emit_responses([], _callback) do
    {:ok, %{text: "", tool_calls: [], finish_reason: "stop", usage: %{}}}
  end

  defp emit_responses(responses, callback) do
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
