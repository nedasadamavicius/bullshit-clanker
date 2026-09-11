defmodule BC.SessionTest do
  use ExUnit.Case

  alias BC.Config
  alias BC.Events
  alias BC.KB.Board
  alias BC.Model.Fake
  alias BC.Session
  alias BC.BoardJob

  setup do
    # Create a test config
    config = %Config{
      kb_root: "/tmp/kb",
      tree_root: "/tmp/tree",
      model: "test",
      ingest_model: "test",
      build_model: nil,
      api_base: "http://localhost:8000",
      api_key: "test-key",
      tamago_go: "tamago-go",
      build_timeout_ms: 120_000
    }

    # Reset Fake model to use default implementation
    Application.put_env(:bc, :model_client, BC.Model.Fake)

    # Mock the KB.Index.all() to return empty list
    Application.put_env(:bc, :kb_boards, [])

    {:ok, config: config}
  end

  describe "send_message/2 with text-only response" do
    test "produces delta events, assistant message, and turn_finished", %{config: config} do
      # Set up fake model to return text only
      fake_responses = [{:text, "Hello, world!"}]
      Application.put_env(:bc, :fake_model, Fake.script(fake_responses))

      # Start a session
      {:ok, session_id, _pid} = BoardJob.Supervisor.start_session(config: config)
      Events.subscribe(session_id)

      # Send a message
      :ok = Session.send_message(session_id, "Hi there")

      # Wait for events
      assert_receive {:bc_event, %{type: :user_message, text: "Hi there"}}, 1000
      assert_receive {:bc_event, %{type: :assistant_delta, text: "Hello, world!"}}, 1000
      assert_receive {:bc_event, %{type: :assistant_message, text: "Hello, world!"}}, 1000
      assert_receive {:bc_event, %{type: :turn_finished, reason: :ok}}, 1000

      # Check transcript
      transcript = Session.transcript(session_id)
      # system, user, assistant
      assert length(transcript) >= 3
      assert Enum.any?(transcript, fn m -> m.role == :user && m.content == "Hi there" end)

      assert Enum.any?(transcript, fn m ->
               m.role == :assistant && m.content == "Hello, world!"
             end)
    end
  end

  describe "send_message/2 with tool calls" do
    test "tool calls execute in order", %{config: config} do
      # Set up fake model with multiple turns
      # Turn 1: tool call
      # Turn 2: response text
      turn_1 = [{:tool_call, "kb.search", %{"soc" => "imx6ul"}}]
      turn_2 = [{:text, "Found something"}]
      fake_config = Fake.script_many([turn_1, turn_2])
      Application.put_env(:bc, :fake_model, fake_config)

      {:ok, session_id, _pid} = BoardJob.Supervisor.start_session(config: config)
      Events.subscribe(session_id)

      :ok = Session.send_message(session_id, "Search for imx6ul")

      # Wait for user message
      assert_receive {:bc_event, %{type: :user_message}}, 1000

      # Wait for tool call started
      assert_receive {:bc_event, %{type: :tool_call_started, name: "kb.search"}}, 2000

      # Wait for tool call finished
      assert_receive {:bc_event, %{type: :tool_call_finished, name: "kb.search"}}, 1000

      # Wait for next model call, then the message
      assert_receive {:bc_event, %{type: :assistant_message}}, 2000
      assert_receive {:bc_event, %{type: :turn_finished, reason: :ok}}, 1000

      # Check transcript includes tool message
      transcript = Session.transcript(session_id)
      assert Enum.any?(transcript, fn m -> m.role == :tool end)
    end
  end

  describe "cancel/1" do
    test "can be called and returns ok", %{config: config} do
      {:ok, session_id, _pid} = BoardJob.Supervisor.start_session(config: config)

      # Should be able to cancel even with no running turn
      :ok = Session.cancel(session_id)

      # Transcript should still be accessible
      transcript = Session.transcript(session_id)
      assert is_list(transcript)
    end

    test "leaves transcript well-formed with matching tool messages when not mid-turn", %{
      config: config
    } do
      # Set up fake model with tool calls
      turn_1 = [
        {:tool_call, "kb.search", %{"soc" => "imx6ul"}},
        {:tool_call, "kb.read", %{"path" => "boards/test/board.toml"}}
      ]

      turn_2 = [{:text, "Done"}]
      fake_config = Fake.script_many([turn_1, turn_2])
      Application.put_env(:bc, :fake_model, fake_config)

      {:ok, session_id, _pid} = BoardJob.Supervisor.start_session(config: config)
      Events.subscribe(session_id)

      # Start a message and wait for it to finish
      :ok = Session.send_message(session_id, "Do something")
      assert_receive {:bc_event, %{type: :turn_finished}}, 2000

      # After turn finishes, check that transcript is well-formed
      transcript = Session.transcript(session_id)

      # Every assistant message with tool_calls should have matching tool messages
      assistant_indices =
        transcript
        |> Enum.with_index()
        |> Enum.filter(fn {msg, _} -> msg.role == :assistant && msg.tool_calls end)
        |> Enum.map(fn {msg, idx} -> {idx, msg.tool_calls} end)

      Enum.each(assistant_indices, fn {assistant_idx, tool_calls} ->
        tool_call_ids = Enum.map(tool_calls, & &1.id)

        tool_message_ids =
          transcript
          |> Enum.drop(assistant_idx + 1)
          |> Enum.take_while(fn m -> m.role == :tool end)
          |> Enum.map(fn m -> m.tool_call_id end)

        # All tool calls should have matching tool messages
        Enum.each(tool_call_ids, fn id ->
          assert id in tool_message_ids, "Tool call #{id} has no matching message"
        end)
      end)
    end
  end

  describe "transcript/1" do
    test "remains responsive when model errors", %{config: config} do
      # Set up model client to error
      Application.put_env(:bc, :model_client, ErrorModel)

      {:ok, session_id, _pid} = BoardJob.Supervisor.start_session(config: config)
      Events.subscribe(session_id)

      :ok = Session.send_message(session_id, "Test")
      assert_receive {:bc_event, %{type: :user_message}}, 1000
      assert_receive {:bc_event, %{type: :error, stage: :model}}, 2000
      assert_receive {:bc_event, %{type: :turn_finished, reason: :error}}, 1000

      # Should still be able to get transcript
      transcript = Session.transcript(session_id)
      assert transcript != nil
      assert is_list(transcript)
    end
  end

  describe "set_draft/2" do
    test "updates draft and regenerates system prompt", %{config: config} do
      {:ok, session_id, _pid} = BoardJob.Supervisor.start_session(config: config)

      # Create a draft board
      draft = %Board{
        id: "test_board",
        source_path: "boards/test/board.toml",
        soc: "imx6ul",
        soc_key: nil,
        goarch: "arm",
        goarm: "7",
        ram_start: 0x80000000,
        ram_size: 0x20000000,
        uart: "UART2",
        peripherals: ["gpio", "usb"],
        pinmux: [],
        tamago_soc: "imx6",
        tamago_board: "mx6ulpico",
        schematic: "boards/test/schematic.pdf",
        tree: "github.com/test/tree",
        notes: "Test board",
        raw: %{}
      }

      # Set draft
      :ok = Session.set_draft(session_id, draft)

      # Get transcript and check system prompt changed
      transcript = Session.transcript(session_id)
      system_msg = Enum.find(transcript, fn m -> m.role == :system end)

      # The system prompt should now include the draft facts
      assert String.contains?(system_msg.content, "test_board")
      assert String.contains?(system_msg.content, "imx6ul")
    end
  end

  describe "max steps" do
    test "stops at 12 steps with max_steps reason", %{config: config} do
      # Create a fake model that returns tool calls in every turn
      # We'll create 13 turns of tool calls to exceed the limit
      turns =
        Enum.map(1..13, fn i ->
          [{:tool_call, "kb.search", %{"soc" => "step_#{i}"}}]
        end)

      fake_config = Fake.script_many(turns)
      Application.put_env(:bc, :fake_model, fake_config)

      {:ok, session_id, _pid} = BoardJob.Supervisor.start_session(config: config)
      Events.subscribe(session_id)

      :ok = Session.send_message(session_id, "Search repeatedly")
      assert_receive {:bc_event, %{type: :user_message}}, 1000

      # Wait for the max steps to be reached
      assert_receive {:bc_event, %{type: :turn_finished, reason: :max_steps}}, 3000

      # Verify transcript has system note about step limit
      transcript = Session.transcript(session_id)

      assert Enum.any?(transcript, fn m ->
               m.role == :system && String.contains?(m.content, "Step limit")
             end)
    end
  end

  describe "two concurrent sessions" do
    test "run independently without sharing state", %{config: config} do
      Application.put_env(:bc, :fake_model, Fake.script([{:text, "Response 1"}]))

      {:ok, session_id_1, _pid_1} = BoardJob.Supervisor.start_session(config: config)
      Events.subscribe(session_id_1)

      {:ok, session_id_2, _pid_2} = BoardJob.Supervisor.start_session(config: config)
      Events.subscribe(session_id_2)

      # Send messages to both
      :ok = Session.send_message(session_id_1, "Message 1")
      :ok = Session.send_message(session_id_2, "Message 2")

      # Wait for events from session 1
      assert_receive {:bc_event,
                      %{session_id: ^session_id_1, type: :user_message, text: "Message 1"}},
                     1000

      assert_receive {:bc_event, %{session_id: ^session_id_1, type: :turn_finished}}, 2000

      # Wait for events from session 2
      assert_receive {:bc_event,
                      %{session_id: ^session_id_2, type: :user_message, text: "Message 2"}},
                     1000

      assert_receive {:bc_event, %{session_id: ^session_id_2, type: :turn_finished}}, 2000

      # Transcripts should be different
      transcript_1 = Session.transcript(session_id_1)
      transcript_2 = Session.transcript(session_id_2)

      # Find user messages
      user_msg_1 = Enum.find(transcript_1, fn m -> m.role == :user end)
      user_msg_2 = Enum.find(transcript_2, fn m -> m.role == :user end)

      assert user_msg_1.content == "Message 1"
      assert user_msg_2.content == "Message 2"
    end
  end
end

# Test double for model errors
defmodule ErrorModel do
  @behaviour BC.Model

  @impl true
  def chat(_messages, _opts, _callback) do
    {:error, %{code: :test_error, message: "Test error"}}
  end
end
