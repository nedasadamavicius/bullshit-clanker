defmodule BC.TUI.ModelTest do
  use ExUnit.Case
  alias BC.TUI.Model

  setup do
    # Set up test config and model
    config = %BC.Config{
      kb_root: "/test/kb",
      tree_root: "/test/tree",
      model: "gpt-4",
      ingest_model: "gpt-4",
      build_model: nil,
      api_base: "http://api.example.com",
      api_key: "test-key",
      tamago_go: "tamago-go",
      build_timeout_ms: 120_000
    }

    model = Model.init("s_test123", config, 5, self())

    %{
      config: config,
      model: model
    }
  end

  describe "initialization" do
    test "creates initial state", %{model: model} do
      assert model.mode == :insert
      assert model.input == ""
      assert model.transcript == []
      assert model.tool_trace == []
      assert model.pending_proposal == nil
      assert model.session_down? == false
      assert model.build_state == :idle
    end
  end

  describe "user input events" do
    test "command letters remain typeable in insert mode", %{model: model} do
      result =
        Enum.reduce([:char_q, :char_i, :char_a, :char_b], model, fn key, state ->
          Model.update(state, {:key, key})
        end)

      assert result.input == "qiab"
    end

    test "user_message event appends to transcript", %{model: model} do
      event = {:bc_event, %{type: :user_message, text: "hello", session_id: "s_test123"}}
      new_model = Model.update(model, event)

      assert new_model.transcript == ["user: hello"]
    end

    test "assistant_delta events append to last assistant line", %{model: model} do
      event1 = {:bc_event, %{type: :user_message, text: "hello", session_id: "s_test123"}}
      event2 = {:bc_event, %{type: :assistant_delta, text: "hi", session_id: "s_test123"}}
      event3 = {:bc_event, %{type: :assistant_delta, text: " there", session_id: "s_test123"}}

      model1 = Model.update(model, event1)
      model2 = Model.update(model1, event2)
      model3 = Model.update(model2, event3)

      assert model3.transcript == ["user: hello", "assistant: hi there"]
    end

    test "assistant_message event adds new assistant message", %{model: model} do
      event =
        {:bc_event, %{type: :assistant_message, text: "full response", session_id: "s_test123"}}

      new_model = Model.update(model, event)

      assert new_model.transcript == ["assistant: full response"]
    end
  end

  describe "tool call events" do
    test "tool_call_started event adds to trace", %{model: model} do
      event = {
        :bc_event,
        %{
          type: :tool_call_started,
          call_id: "call_001",
          name: "kb.search",
          args: %{"query" => "imx6"},
          session_id: "s_test123"
        }
      }

      new_model = Model.update(model, event)
      assert new_model.tool_trace == ["[call_001] kb.search ..."]
    end

    test "tool_call_finished event updates trace with result", %{model: model} do
      start_event = {
        :bc_event,
        %{
          type: :tool_call_started,
          call_id: "call_001",
          name: "kb.search",
          args: %{"query" => "imx6"},
          session_id: "s_test123"
        }
      }

      finish_event = {
        :bc_event,
        %{
          type: :tool_call_finished,
          call_id: "call_001",
          name: "kb.search",
          ok: true,
          summary: "found 3 boards",
          duration_ms: 45,
          session_id: "s_test123"
        }
      }

      model1 = Model.update(model, start_event)
      model2 = Model.update(model1, finish_event)

      assert model2.tool_trace == [
               "[call_001] kb.search ...",
               "[call_001] kb.search ok 45ms found 3 boards"
             ]
    end
  end

  describe "proposal events" do
    test "proposal event opens patch pane", %{model: model} do
      event = {
        :bc_event,
        %{
          type: :proposal,
          proposal_id: "p_abc123",
          nearest_board_id: "mk2",
          summary: "Set tamago_board to imx6ulevk",
          citations: [%{"path" => "boards/mk2/board.toml", "claim" => "found soc: imx6ul"}],
          deltas: [
            %{
              "field" => "tamago_board",
              "draft" => "unknown",
              "board" => "imx6ulevk",
              "kind" => "unknown_in_draft"
            }
          ],
          patch: "--- a/boards/mk2/board.toml\n+++ b/boards/mk2/board.toml\n",
          session_id: "s_test123"
        }
      }

      new_model = Model.update(model, event)

      assert new_model.pending_proposal != nil
      assert new_model.pending_proposal.id == "p_abc123"
      assert new_model.pending_proposal.nearest_board_id == "mk2"
      assert new_model.pending_proposal.status == :pending
      assert length(new_model.pending_proposal.deltas) == 1
      assert length(new_model.pending_proposal.citations) == 1
    end

    test "proposal_invalid event shows reasons", %{model: model} do
      event = {
        :bc_event,
        %{
          type: :proposal_invalid,
          proposal_id: "p_bad123",
          reasons: ["Uncited claim: soc claimed but not read", "Path not in KB"],
          session_id: "s_test123"
        }
      }

      new_model = Model.update(model, event)

      assert Enum.any?(new_model.transcript, &String.contains?(&1, "invalid"))
    end
  end

  describe "apply/reject flow (I4)" do
    setup %{model: model} do
      # Create a proposal in the model
      proposal_event = {
        :bc_event,
        %{
          type: :proposal,
          proposal_id: "p_apply123",
          nearest_board_id: "mk2",
          summary: "Update board config",
          citations: [%{"path" => "boards/mk2/board.toml", "claim" => "found it"}],
          deltas: [
            %{"field" => "soc", "draft" => "imx6ul", "board" => "imx6ul", "kind" => "same"}
          ],
          patch: "--- a/file\n+++ b/file\n@@ -1 +1 @@\n-old\n+new\n",
          session_id: "s_test123"
        }
      }

      model_with_proposal = Model.update(model, proposal_event)
      %{model_with_proposal: model_with_proposal}
    end

    test "'a' in normal mode with proposal sets confirm state", %{model_with_proposal: model} do
      # Switch to normal mode
      model_normal = %{model | mode: :normal}

      # Press 'a'
      new_model = Model.update(model_normal, {:key, :char_a})

      assert new_model.confirm_state == {:pending_proposal_apply, "p_apply123"}
      assert String.contains?(new_model.status_message, "apply")
    end

    test "'a' with no proposal is a no-op", %{model: model} do
      model_normal = %{model | mode: :normal}
      new_model = Model.update(model_normal, {:key, :char_a})

      assert new_model.confirm_state == :none
      assert new_model.apply_hint == "(no pending proposal)"
    end

    test "'a' in insert mode types 'a'", %{model_with_proposal: model} do
      # In insert mode, 'a' should be typed as a character
      # Note: 97 is the character code for 'a'
      # For testing, we simulate typing
      new_model = Model.update(model, {:key, 97})

      assert new_model.input == "a"
      assert new_model.confirm_state == :none
    end

    test "'y' after 'a' mints permit and applies", %{model_with_proposal: model} do
      # Set up test seams
      Application.put_env(:bc, :patch_applier, BC.Test.FakePatchApplier)

      model_normal = %{model | mode: :normal}

      # Press 'a'
      model_confirm = Model.update(model_normal, {:key, :char_a})
      assert model_confirm.confirm_state == {:pending_proposal_apply, "p_apply123"}

      # Press 'y'
      model_applied = Model.update(model_confirm, {:key, :char_y})

      # Confirm state should be cleared
      assert model_applied.confirm_state == :none
      # Status message should be cleared
      assert model_applied.status_message == nil
    end

    test "'n' after 'a' cancels confirmation", %{model_with_proposal: model} do
      model_normal = %{model | mode: :normal}

      # Press 'a'
      model_confirm = Model.update(model_normal, {:key, :char_a})
      assert model_confirm.confirm_state == {:pending_proposal_apply, "p_apply123"}

      # Press 'n' (any key but 'y' cancels)
      model_cancelled = Model.update(model_confirm, {:key, :char_n})

      assert model_cancelled.confirm_state == :none
      assert model_cancelled.status_message == nil
    end

    test "apply_result with ok: true closes patch pane", %{
      model_with_proposal: model_with_proposal
    } do
      event = {
        :bc_event,
        %{
          type: :apply_result,
          proposal_id: "p_apply123",
          ok: true,
          output: "Applied 1 file",
          session_id: "s_test123"
        }
      }

      new_model = Model.update(model_with_proposal, event)

      assert new_model.pending_proposal == nil
      assert Enum.any?(new_model.transcript, &String.contains?(&1, "applied"))
    end

    test "apply_result with ok: false keeps patch pane open", %{
      model_with_proposal: model_with_proposal
    } do
      event = {
        :bc_event,
        %{
          type: :apply_result,
          proposal_id: "p_apply123",
          ok: false,
          output: "Conflict in file.txt",
          session_id: "s_test123"
        }
      }

      new_model = Model.update(model_with_proposal, event)

      assert new_model.pending_proposal != nil
      assert Enum.any?(new_model.transcript, &String.contains?(&1, "apply failed"))
    end
  end

  describe "build events" do
    test "build_started event sets state to building", %{model: model} do
      event = {
        :bc_event,
        %{
          type: :build_started,
          build_id: "b_001",
          argv: ["tamago-go", "build"],
          session_id: "s_test123"
        }
      }

      new_model = Model.update(model, event)
      assert new_model.build_state == :building
    end

    test "build_finished event with exit status updates state", %{model: model} do
      started_event = {
        :bc_event,
        %{
          type: :build_started,
          build_id: "b_001",
          argv: ["tamago-go", "build"],
          session_id: "s_test123"
        }
      }

      finished_event = {
        :bc_event,
        %{
          type: :build_finished,
          build_id: "b_001",
          exit_status: 0,
          duration_ms: 5000,
          timed_out: false,
          session_id: "s_test123"
        }
      }

      model1 = Model.update(model, started_event)
      model2 = Model.update(model1, finished_event)

      assert model2.build_state == {:exit, 0}
    end

    test "build_finished event with timed_out flag", %{model: model} do
      started_event = {
        :bc_event,
        %{
          type: :build_started,
          build_id: "b_001",
          argv: ["tamago-go", "build"],
          session_id: "s_test123"
        }
      }

      finished_event = {
        :bc_event,
        %{
          type: :build_finished,
          build_id: "b_001",
          exit_status: 124,
          duration_ms: 120_000,
          timed_out: true,
          session_id: "s_test123"
        }
      }

      model1 = Model.update(model, started_event)
      model2 = Model.update(model1, finished_event)

      assert model2.build_state == :timed_out
    end
  end

  describe "session handling" do
    test "session DOWN message sets flag", %{model: model} do
      down_event = {:DOWN, make_ref(), :process, model.session_pid, :normal}
      new_model = Model.update(model, down_event)

      assert new_model.session_down? == true
    end
  end

  describe "mode switching" do
    test "Esc in insert mode switches to normal", %{model: model} do
      model_insert = %{model | mode: :insert}
      new_model = Model.update(model_insert, {:key, :esc})

      assert new_model.mode == :normal
    end

    test "'i' in normal mode switches to insert", %{model: model} do
      model_normal = %{model | mode: :normal}
      new_model = Model.update(model_normal, {:key, :char_i})

      assert new_model.mode == :insert
    end
  end

  describe "text input" do
    test "typing characters in insert mode appends to input", %{model: model} do
      model_insert = %{model | mode: :insert}
      new_model = Model.update(model_insert, {:key, 104})

      # 104 is 'h'
      assert new_model.input == "h"
    end

    test "backspace removes last character", %{model: model} do
      model_input = %{model | mode: :insert, input: "hello"}
      new_model = Model.update(model_input, {:key, :backspace})

      assert new_model.input == "hell"
    end

    test "backspace on empty input does nothing", %{model: model} do
      model_insert = %{model | mode: :insert, input: ""}
      new_model = Model.update(model_insert, {:key, :backspace})

      assert new_model.input == ""
    end

    test "Enter sends message and clears input", %{model: model} do
      model_input = %{model | mode: :insert, input: "search for imx6"}
      # We'll just verify the state changes; the actual Session.send_message is external
      new_model = Model.update(model_input, {:key, :enter})

      assert new_model.input == ""
      assert new_model.mode == :normal
    end
  end

  describe "error events" do
    test "error event appends to transcript", %{model: model} do
      event = {
        :bc_event,
        %{
          type: :error,
          stage: :model,
          message: "API rate limit exceeded",
          session_id: "s_test123"
        }
      }

      new_model = Model.update(model, event)

      assert Enum.any?(new_model.transcript, &String.contains?(&1, "error"))
    end
  end

  describe "scrolling" do
    test "'j' scrolls focused pane down", %{model: model} do
      model_normal = %{model | mode: :normal, focused_pane: :transcript}
      new_model = Model.update(model_normal, {:key, :char_j})

      assert new_model.transcript_scroll == 1
    end

    test "'k' scrolls focused pane up", %{model: model} do
      model_normal = %{model | mode: :normal, focused_pane: :transcript, transcript_scroll: 5}
      new_model = Model.update(model_normal, {:key, :char_k})

      assert new_model.transcript_scroll == 4
    end

    test "scroll does not go below 0", %{model: model} do
      model_normal = %{model | mode: :normal, focused_pane: :transcript, transcript_scroll: 0}
      new_model = Model.update(model_normal, {:key, :char_k})

      assert new_model.transcript_scroll == 0
    end

    test "Tab cycles focus pane", %{model: model} do
      model_normal = %{model | mode: :normal, focused_pane: :transcript}
      model1 = Model.update(model_normal, {:key, :tab})
      assert model1.focused_pane == :trace

      model2 = Model.update(model1, {:key, :tab})
      assert model2.focused_pane == :patch

      model3 = Model.update(model2, {:key, :tab})
      assert model3.focused_pane == :transcript
    end
  end

  describe "API key safety (10)" do
    test "API key does not appear in rendered output", %{model: model, config: config} do
      model_with_key = %{model | config: config}
      rendered = Model.render(model_with_key)

      # Verify that the API key doesn't appear in any rendered text
      refute String.contains?(rendered, config.api_key)
    end
  end

  describe "proposal pane rendering" do
    test "delta table renders correctly", %{model: model} do
      proposal_event = {
        :bc_event,
        %{
          type: :proposal,
          proposal_id: "p_delta",
          nearest_board_id: "mk2",
          summary: "Test deltas",
          citations: [],
          deltas: [
            %{"field" => "soc", "draft" => "imx6ul", "board" => "imx6ul", "kind" => "same"},
            %{
              "field" => "tamago_board",
              "draft" => "unknown",
              "board" => "imx6ulevk",
              "kind" => "unknown_in_draft"
            }
          ],
          patch: "--- a/file\n+++ b/file\n",
          session_id: "s_test123"
        }
      }

      model_with_proposal = Model.update(model, proposal_event)

      assert model_with_proposal.pending_proposal != nil
      assert length(model_with_proposal.pending_proposal.deltas) == 2
    end

    test "citations with claims render correctly", %{model: model} do
      proposal_event = {
        :bc_event,
        %{
          type: :proposal,
          proposal_id: "p_cite",
          nearest_board_id: "mk2",
          summary: "Test citations",
          citations: [
            %{"path" => "boards/mk2/board.toml", "claim" => "found soc: imx6ul"},
            %{"path" => "boards/stm32/board.toml", "claim" => "found uart: UART1"}
          ],
          deltas: [],
          patch: "--- a/file\n+++ b/file\n",
          session_id: "s_test123"
        }
      }

      model_with_proposal = Model.update(model, proposal_event)

      assert length(model_with_proposal.pending_proposal.citations) == 2

      assert Enum.any?(model_with_proposal.pending_proposal.citations, fn c ->
               c["claim"] == "found soc: imx6ul"
             end)
    end
  end
end
