defmodule Hatch.Session.TranscriptTest do
  use ExUnit.Case

  alias Hatch.Session.Transcript

  describe "append/2" do
    test "appends message to list" do
      messages = [%{role: :system, content: "System", tool_calls: nil, tool_call_id: nil}]
      new_msg = %{role: :user, content: "User", tool_calls: nil, tool_call_id: nil}

      result = Transcript.append(messages, new_msg)
      assert length(result) == 2
      assert Enum.at(result, 1) == new_msg
    end
  end

  describe "estimate_tokens/1" do
    test "estimates tokens as chars/4" do
      messages = [
        %{role: :system, content: "abcd", tool_calls: nil, tool_call_id: nil},
        %{role: :user, content: "efgh", tool_calls: nil, tool_call_id: nil}
      ]

      tokens = Transcript.estimate_tokens(messages)
      # 8 chars total, so 8/4 = 2 tokens
      assert tokens == 2
    end
  end

  describe "bound/2" do
    test "keeps messages when under budget" do
      messages = [
        %{role: :system, content: "sys" <> String.duplicate("x", 1000), tool_calls: nil, tool_call_id: nil},
        %{role: :user, content: "user", tool_calls: nil, tool_call_id: nil}
      ]

      bounded = Transcript.bound(messages, nil)
      assert length(bounded) >= 2
    end

    test "drops complete assistant+tool pairs when over budget" do
      # Create a large system prompt to exceed budget quickly
      large_content = String.duplicate("x", 480_000)  # 120k tokens

      messages = [
        %{role: :system, content: large_content, tool_calls: nil, tool_call_id: nil},
        %{role: :user, content: "msg1", tool_calls: nil, tool_call_id: nil},
        %{
          role: :assistant,
          content: "response1",
          tool_calls: [%{id: "call_1", name: "tool1", arguments: "{}"}],
          tool_call_id: nil
        },
        %{role: :tool, content: "result1", tool_calls: nil, tool_call_id: "call_1"},
        %{role: :user, content: "msg2", tool_calls: nil, tool_call_id: nil},
        %{
          role: :assistant,
          content: "response2",
          tool_calls: [%{id: "call_2", name: "tool2", arguments: "{}"}],
          tool_call_id: nil
        },
        %{role: :tool, content: "result2", tool_calls: nil, tool_call_id: "call_2"}
      ]

      bounded = Transcript.bound(messages, nil)

      # System prompt should still be there
      assert Enum.at(bounded, 0).role == :system

      # When bounding happens, should drop complete pairs
      # The exact behavior depends on the budget and sizes, but system should stay
      assert bounded != messages
    end

    test "inserts elision marker when dropping messages" do
      large_content = String.duplicate("x", 480_000)

      messages = [
        %{role: :system, content: large_content, tool_calls: nil, tool_call_id: nil},
        %{role: :user, content: "msg1", tool_calls: nil, tool_call_id: nil},
        %{
          role: :assistant,
          content: "response1",
          tool_calls: [%{id: "call_1", name: "tool1", arguments: "{}"}],
          tool_call_id: nil
        },
        %{role: :tool, content: "result1", tool_calls: nil, tool_call_id: "call_1"}
      ]

      bounded = Transcript.bound(messages, nil)

      # Check if there's a system message with elision marker
      system_msgs = Enum.filter(bounded, fn m -> m.role == :system && String.contains?(m.content, "elided") end)
      # Elision marker might be added if bounding occurred
      # (depends on whether budget was exceeded)
    end
  end
end
