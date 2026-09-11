defmodule Hatch.EventsTest do
  use ExUnit.Case

  describe "topic/1" do
    test "returns topic string prefixed with session:" do
      topic = Hatch.Events.topic("s_12345678")
      assert topic == "session:s_12345678"
    end
  end

  describe "subscribe/1" do
    test "subscribes to session topic" do
      session_id = "s_test0001"
      :ok = Hatch.Events.subscribe(session_id)
      # Successfully subscribed without error
    end
  end

  describe "broadcast/2" do
    test "delivers events to subscribed listeners" do
      session_id = "s_test0002"
      Hatch.Events.subscribe(session_id)

      event = %{type: :test_event, data: "test"}
      :ok = Hatch.Events.broadcast(session_id, event)

      assert_receive {:hatch_event, received_event}
      assert received_event.type == :test_event
      assert received_event.data == "test"
      assert received_event.session_id == session_id
    end

    test "injects session_id into event" do
      session_id = "s_test0003"
      Hatch.Events.subscribe(session_id)

      event = %{type: :test_event}
      :ok = Hatch.Events.broadcast(session_id, event)

      assert_receive {:hatch_event, received_event}
      assert received_event.session_id == session_id
    end

    test "does not deliver to different session subscribers" do
      session_a = "s_testa0001"
      session_b = "s_testb0001"

      Hatch.Events.subscribe(session_a)
      Hatch.Events.subscribe(session_b)

      event = %{type: :test_event}
      :ok = Hatch.Events.broadcast(session_a, event)

      assert_receive {:hatch_event, received_event}
      assert received_event.session_id == session_a

      # Should not receive session_b event
      refute_receive {:hatch_event, %{session_id: ^session_b}}, 100
    end

    test "delivers to multiple subscribers of same session" do
      session_id = "s_test0004"
      Hatch.Events.subscribe(session_id)
      Hatch.Events.subscribe(session_id)

      event = %{type: :test_event}
      :ok = Hatch.Events.broadcast(session_id, event)

      assert_receive {:hatch_event, _event1}
      assert_receive {:hatch_event, _event2}
    end
  end
end
