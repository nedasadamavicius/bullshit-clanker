defmodule BC.Session.Transcript do
  @moduledoc """
  Message list with token bounding.

  System prompt at index 0 is never dropped. When token budget is exceeded,
  drop complete assistant+tool pairs from the oldest non-system messages.
  """

  @type t :: [BC.Model.message()]

  @budget 120_000

  @spec append(t(), BC.Model.message()) :: t()
  def append(messages, new_msg) do
    messages ++ [new_msg]
  end

  @spec bound(t(), BC.Model.message() | nil) :: t()
  def bound(messages, system_prompt) when is_list(messages) do
    case estimate_tokens(messages) do
      tokens when tokens > @budget ->
        # Drop oldest non-system messages, always in complete assistant+tool pairs
        drop_oldest_group(messages, system_prompt)

      _ ->
        messages
    end
  end

  @spec estimate_tokens(t()) :: non_neg_integer()
  def estimate_tokens(messages) do
    messages
    |> Enum.map(fn msg ->
      content = msg[:content] || ""
      String.length(content)
    end)
    |> Enum.sum()
    |> div(4)
  end

  # Drop the oldest non-system assistant+tool pair, or a single message
  defp drop_oldest_group([system_prompt | rest], _) when is_list(rest) do
    case find_first_complete_group(rest) do
      {[], []} ->
        # No complete pair found, just keep system and drop the next message if it's not too important
        [system_prompt | rest]

      {prefix, group, suffix} ->
        # Found a group, drop it and check again
        new_messages = [system_prompt | prefix ++ suffix]

        # Recursively bound if still over budget
        case estimate_tokens(new_messages) do
          tokens when tokens > @budget ->
            # Add elision marker
            marker = %{
              role: :system,
              content: "[... #{Enum.count(group)} messages elided ...]",
              tool_calls: nil,
              tool_call_id: nil
            }

            bound([system_prompt | prefix ++ [marker | suffix]], nil)

          _ ->
            new_messages
        end
    end
  end

  defp drop_oldest_group(messages, _), do: messages

  # Find the first complete assistant+tool pair
  # Returns {messages_before, group_to_drop, messages_after}
  defp find_first_complete_group(messages) do
    find_first_complete_group_impl(messages, [])
  end

  defp find_first_complete_group_impl([], _acc) do
    {[], [], []}
  end

  defp find_first_complete_group_impl(
         [%{role: :assistant, tool_calls: tool_calls} = assistant | rest],
         acc
       )
       when is_list(tool_calls) and length(tool_calls) > 0 do
    # Found an assistant message with tool calls, look for matching tool messages
    {tools, remaining} = extract_matching_tools(rest, length(tool_calls), [])

    if length(tools) == length(tool_calls) do
      # Found a complete pair
      group = [assistant | tools]
      {Enum.reverse(acc), group, remaining}
    else
      # Incomplete, continue searching
      find_first_complete_group_impl(rest, [assistant | acc])
    end
  end

  defp find_first_complete_group_impl([msg | rest], acc) do
    find_first_complete_group_impl(rest, [msg | acc])
  end

  # Extract tool messages that match the count
  defp extract_matching_tools(messages, count, acc) when count <= 0 do
    {Enum.reverse(acc), messages}
  end

  defp extract_matching_tools([%{role: :tool} = tool | rest], count, acc) do
    extract_matching_tools(rest, count - 1, [tool | acc])
  end

  defp extract_matching_tools(messages, count, acc) when count > 0 do
    # Ran out of tool messages
    {Enum.reverse(acc), messages}
  end
end
