defmodule BC.TUI.Model do
  @moduledoc """
  Pure state management for the TUI.

  The model is a plain Elixir struct updated by the update/2 function
  given events. No side effects, no I/O — only state transformations.
  """

  require Logger

  alias BC.KB.Delta
  alias BC.Proposal

  @type mode :: :normal | :insert

  @type confirm_state ::
          :none
          | {:pending_proposal_apply, proposal_id :: String.t()}
          | {:pending_reject, proposal_id :: String.t()}

  @type focused_pane :: :transcript | :trace | :patch

  @type t :: %__MODULE__{
          mode: mode(),
          session_id: String.t(),
          config: BC.Config.t(),
          session_pid: pid() | nil,
          session_down?: boolean(),
          input: String.t(),
          transcript: [String.t()],
          transcript_scroll: non_neg_integer(),
          tool_trace: [String.t()],
          trace_scroll: non_neg_integer(),
          pending_proposal: Proposal.t() | nil,
          patch_scroll: non_neg_integer(),
          focused_pane: focused_pane(),
          confirm_state: confirm_state(),
          apply_hint: String.t() | nil,
          build_state: build_state(),
          board_count: non_neg_integer(),
          status_message: String.t() | nil
        }

  @type build_state :: :idle | :building | {:exit, non_neg_integer()} | :timed_out | :no_toolchain

  defstruct [
    :mode,
    :session_id,
    :config,
    :session_pid,
    :session_down?,
    :input,
    :transcript,
    :transcript_scroll,
    :tool_trace,
    :trace_scroll,
    :pending_proposal,
    :patch_scroll,
    :focused_pane,
    :confirm_state,
    :apply_hint,
    :build_state,
    :board_count,
    :status_message
  ]

  @spec init(
          session_id :: String.t(),
          config :: BC.Config.t(),
          board_count :: non_neg_integer(),
          session_pid :: pid()
        ) ::
          t()
  def init(session_id, config, board_count, session_pid) do
    %__MODULE__{
      mode: :insert,
      session_id: session_id,
      config: config,
      session_pid: session_pid,
      session_down?: false,
      input: "",
      transcript: [],
      transcript_scroll: 0,
      tool_trace: [],
      trace_scroll: 0,
      pending_proposal: nil,
      patch_scroll: 0,
      focused_pane: :transcript,
      confirm_state: :none,
      apply_hint: nil,
      build_state: :idle,
      board_count: board_count,
      status_message: nil
    }
  end

  @spec update(t(), any()) :: t()

  # PubSub events wrapped in bc_event
  def update(state, {:bc_event, event}) do
    handle_bc_event(state, event)
  end

  # Session down (monitored process died)
  def update(state, {:DOWN, _ref, :process, pid, _reason}) when pid == state.session_pid do
    %{state | session_down?: true}
  end

  # Keyboard input events (for testing with ExTermbox or other sources)
  def update(state, {:key, key}) do
    handle_key(state, key)
  end

  # Ignore other events
  def update(state, _event) do
    state
  end

  # --- Event handlers ---

  defp handle_key(state, key) do
    case state.mode do
      :insert ->
        handle_insert_key(state, key)

      :normal ->
        handle_normal_key(state, key)
    end
  end

  defp handle_insert_key(state, :esc) do
    %{state | mode: :normal}
  end

  defp handle_insert_key(state, :enter) do
    # Send message and clear input
    text = state.input
    new_state = %{state | input: "", mode: :normal}

    # Broadcast to session - this will be handled externally
    BC.Session.send_message(state.session_id, text)

    new_state
  end

  defp handle_insert_key(state, :"Ctrl+c") do
    # Quit
    {:quit, state}
  end

  defp handle_insert_key(state, :backspace) do
    new_input =
      if String.length(state.input) > 0 do
        String.slice(state.input, 0..-2//1)
      else
        state.input
      end

    %{state | input: new_input}
  end

  defp handle_insert_key(state, key) when is_atom(key) do
    case Atom.to_string(key) do
      "char_" <> char -> %{state | input: state.input <> char}
      _ -> state
    end
  end

  defp handle_insert_key(state, char) when is_integer(char) do
    # Regular character input
    new_input = state.input <> <<char::utf8>>
    %{state | input: new_input}
  end

  defp handle_normal_key(state, :char_i) do
    %{state | mode: :insert}
  end

  defp handle_normal_key(state, :char_j) do
    scroll_pane(state, state.focused_pane, 1)
  end

  defp handle_normal_key(state, :char_k) do
    scroll_pane(state, state.focused_pane, -1)
  end

  defp handle_normal_key(state, :pgdn) do
    scroll_pane(state, state.focused_pane, 5)
  end

  defp handle_normal_key(state, :pgup) do
    scroll_pane(state, state.focused_pane, -5)
  end

  defp handle_normal_key(state, :tab) do
    # Cycle focus: transcript → trace → patch
    new_focus =
      case state.focused_pane do
        :transcript -> :trace
        :trace -> :patch
        :patch -> :transcript
      end

    %{state | focused_pane: new_focus}
  end

  defp handle_normal_key(state, :char_a) do
    handle_accept_key(state)
  end

  defp handle_normal_key(state, :char_r) do
    handle_reject_key(state)
  end

  defp handle_normal_key(state, :char_b) do
    # tamago.build on demand - for now just a hint
    BC.Session.send_message(state.session_id, "tools.build()")
    state
  end

  defp handle_normal_key(state, :char_c) do
    # Cancel the running turn
    BC.Session.cancel(state.session_id)
    state
  end

  defp handle_normal_key(state, :char_q) do
    {:quit, state}
  end

  defp handle_normal_key(state, :"Ctrl+c") do
    {:quit, state}
  end

  defp handle_normal_key(state, :char_y) do
    # Handle confirmation: y for yes
    handle_confirmation_response(state, :yes)
  end

  defp handle_normal_key(state, _key) do
    # Any other key during confirmation cancels it
    case state.confirm_state do
      :none ->
        state

      {:pending_proposal_apply, _proposal_id} ->
        %{state | confirm_state: :none, status_message: nil}

      {:pending_reject, _proposal_id} ->
        %{state | confirm_state: :none, status_message: nil}
    end
  end

  defp handle_confirmation_response(state, :yes) do
    case state.confirm_state do
      {:pending_proposal_apply, proposal_id} ->
        # Mint permit and apply patch
        case state.pending_proposal do
          nil ->
            %{state | confirm_state: :none}

          proposal ->
            # The only TUI call site. mix bc.accept is the other, excluded
            # from the 009 grep test by filename (spec 013).
            patch_hash = Proposal.patch_hash(proposal)
            permit = BC.Permit.mint(proposal_id, state.session_id, patch_hash)

            # Apply the patch asynchronously
            tree_root = state.config.tree_root

            unless tree_root do
              # No tree, just note failure
              new_transcript = state.transcript ++ ["Cannot apply: no tree configured"]
              %{state | transcript: new_transcript, confirm_state: :none, status_message: nil}
            else
              # Call the applier via seam
              applier = Application.get_env(:bc, :patch_applier, BC.Patch.Apply)

              Task.start(fn ->
                case applier.apply_patch(proposal, permit, tree_root) do
                  {:ok, result} ->
                    BC.Session.note_applied(state.session_id, proposal, result[:output])

                  {:error, err} ->
                    BC.Session.note_applied(state.session_id, proposal, err[:message])
                end
              end)

              %{state | confirm_state: :none, status_message: nil}
            end
        end

      {:pending_reject, proposal_id} ->
        # Handle rejection
        case state.pending_proposal do
          nil ->
            %{state | confirm_state: :none}

          proposal ->
            BC.Session.note_rejected(state.session_id, proposal, "")
            %{state | confirm_state: :none, status_message: nil}
        end

      :none ->
        state
    end
  end

  defp handle_accept_key(state) do
    case state.confirm_state do
      :none ->
        # No confirmation pending
        case state.pending_proposal do
          nil ->
            # No pending proposal - no-op with a hint
            %{state | apply_hint: "(no pending proposal)"}

          proposal ->
            # Proposal exists, check if patch pane is focused
            if state.focused_pane in [:patch, :transcript] do
              # Start confirmation sequence
              file_count = count_files_in_patch(proposal.patch)

              %{
                state
                | confirm_state: {:pending_proposal_apply, proposal.id},
                  status_message: "apply #{file_count} files from proposal #{proposal.id}? [y/N]"
              }
            else
              %{state | apply_hint: "(focus patch pane to apply)"}
            end
        end

      {:pending_proposal_apply, _proposal_id} ->
        # Confirmation already pending - ignored in normal mode
        state

      {:pending_reject, _proposal_id} ->
        # Rejection confirmation pending
        state
    end
  end

  defp handle_reject_key(state) do
    case state.pending_proposal do
      nil ->
        state

      proposal ->
        # Start rejection sequence
        %{
          state
          | confirm_state: {:pending_reject, proposal.id},
            status_message: "Rejection reason? (Enter to skip): "
        }
    end
  end

  defp scroll_pane(state, pane, delta) do
    case pane do
      :transcript ->
        new_scroll = max(0, state.transcript_scroll + delta)
        %{state | transcript_scroll: new_scroll}

      :trace ->
        new_scroll = max(0, state.trace_scroll + delta)
        %{state | trace_scroll: new_scroll}

      :patch ->
        new_scroll = max(0, state.patch_scroll + delta)
        %{state | patch_scroll: new_scroll}
    end
  end

  defp handle_bc_event(state, %{type: :user_message, text: text}) do
    new_transcript = state.transcript ++ ["user: #{text}"]
    %{state | transcript: new_transcript}
  end

  defp handle_bc_event(state, %{type: :assistant_delta, text: text}) do
    # Append to last assistant line or create new one
    new_transcript =
      case state.transcript do
        [] ->
          ["assistant: " <> text]

        lines ->
          last_line = List.last(lines)

          if String.starts_with?(last_line, "assistant: ") do
            List.replace_at(lines, -1, last_line <> text)
          else
            lines ++ ["assistant: " <> text]
          end
      end

    %{state | transcript: new_transcript}
  end

  defp handle_bc_event(state, %{type: :assistant_message, text: text}) do
    new_transcript = state.transcript ++ ["assistant: #{text}"]
    %{state | transcript: new_transcript}
  end

  defp handle_bc_event(state, %{
         type: :tool_call_started,
         call_id: call_id,
         name: name,
         args: _args
       }) do
    new_trace = state.tool_trace ++ ["[#{call_id}] #{name} ..."]
    %{state | tool_trace: new_trace}
  end

  defp handle_bc_event(
         state,
         %{
           type: :tool_call_finished,
           call_id: call_id,
           name: name,
           ok: ok,
           summary: summary,
           duration_ms: duration
         }
       ) do
    status = if ok, do: "ok", else: "err"
    summary_short = String.slice(summary, 0..79)

    new_trace =
      state.tool_trace ++ ["[#{call_id}] #{name} #{status} #{duration}ms #{summary_short}"]

    %{state | tool_trace: new_trace}
  end

  defp handle_bc_event(
         state,
         %{
           type: :proposal,
           proposal_id: proposal_id,
           nearest_board_id: nearest_board_id,
           summary: summary,
           citations: citations,
           deltas: deltas,
           patch: patch
         }
       ) do
    # Convert maps to proper structs
    proposal = %Proposal{
      id: proposal_id,
      session_id: state.session_id,
      nearest_board_id: nearest_board_id,
      summary: summary,
      citations: citations,
      deltas:
        Enum.map(deltas, fn d ->
          %Delta{
            field: String.to_atom(d["field"]),
            draft: d["draft"],
            board: d["board"],
            kind: String.to_atom(d["kind"])
          }
        end),
      patch: patch,
      status: :pending,
      invalid_reasons: [],
      created_at: DateTime.utc_now()
    }

    new_transcript = state.transcript ++ ["proposal: #{summary}"]

    %{
      state
      | pending_proposal: proposal,
        transcript: new_transcript,
        confirm_state: :none,
        status_message: nil,
        apply_hint: nil
    }
  end

  defp handle_bc_event(state, %{
         type: :proposal_invalid,
         proposal_id: proposal_id,
         reasons: reasons
       }) do
    new_transcript =
      state.transcript ++ ["proposal #{proposal_id} invalid: " <> Enum.join(reasons, "; ")]

    %{state | transcript: new_transcript}
  end

  defp handle_bc_event(state, %{
         type: :apply_result,
         proposal_id: proposal_id,
         ok: ok,
         output: output
       }) do
    new_transcript =
      if ok do
        state.transcript ++ ["applied: #{output}"]
      else
        state.transcript ++ ["apply failed: #{output}"]
      end

    new_state = %{state | transcript: new_transcript}

    if ok do
      # Close patch pane on success
      %{new_state | pending_proposal: nil}
    else
      # Keep patch pane open on failure
      new_state
    end
  end

  defp handle_bc_event(state, %{type: :build_started, build_id: _build_id, argv: _argv}) do
    %{state | build_state: :building}
  end

  defp handle_bc_event(state, %{type: :build_log, build_id: _build_id, chunk: _chunk}) do
    state
  end

  defp handle_bc_event(
         state,
         %{
           type: :build_finished,
           build_id: _build_id,
           exit_status: exit_status,
           duration_ms: _duration,
           timed_out: timed_out
         }
       ) do
    new_build_state =
      if timed_out do
        :timed_out
      else
        {:exit, exit_status}
      end

    %{state | build_state: new_build_state}
  end

  defp handle_bc_event(state, %{type: :turn_finished, reason: _reason}) do
    state
  end

  defp handle_bc_event(state, %{type: :error, stage: stage, message: message}) do
    new_transcript = state.transcript ++ ["error (#{stage}): #{message}"]
    %{state | transcript: new_transcript}
  end

  defp handle_bc_event(state, _event) do
    # Unknown event type - ignore
    state
  end

  # Helper to count files in a unified diff patch
  defp count_files_in_patch(patch_text) do
    patch_text
    |> String.split("\n")
    |> Enum.count(&String.starts_with?(&1, "diff --git"))
  end

  @spec render(t()) :: String.t()
  def render(state) do
    # This is a pure function that returns the rendered view as a string
    # It renders all panes and combines them into ASCII text
    render_layout(state)
  end

  defp render_layout(state) do
    # Simple ASCII layout for now
    transcript_lines = render_transcript_pane(state)
    trace_lines = render_trace_pane(state)
    patch_lines = render_patch_pane(state)
    input_line = render_input_line(state)
    status_line = render_status_bar(state)

    # Combine all lines
    all_lines = transcript_lines ++ trace_lines ++ patch_lines ++ [input_line, status_line]

    Enum.join(all_lines, "\n")
  end

  defp render_transcript_pane(state) do
    state.transcript
    |> Enum.drop(state.transcript_scroll)
    |> Enum.take(10)
  end

  defp render_trace_pane(state) do
    state.tool_trace
    |> Enum.drop(state.trace_scroll)
    |> Enum.take(5)
  end

  defp render_patch_pane(state) do
    case state.pending_proposal do
      nil ->
        []

      proposal ->
        delta_lines = Delta.render(proposal.deltas) |> String.split("\n")
        citation_lines = render_citations(proposal.citations)
        patch_lines = String.split(proposal.patch, "\n") |> Enum.take(10)

        ["[Patch]"] ++ delta_lines ++ citation_lines ++ patch_lines
    end
  end

  defp render_citations(citations) do
    Enum.flat_map(citations, fn %{path: path, claim: claim} ->
      ["  #{path}: #{claim}"]
    end)
  end

  defp render_input_line(state) do
    "> " <> state.input
  end

  defp render_status_bar(state) do
    tree_display = if state.config.tree_root, do: state.config.tree_root, else: "no tree"
    build_display = build_state_display(state.build_state)
    pending = if state.pending_proposal, do: " [pending patch]", else: ""

    "kb=#{state.config.kb_root} boards=#{state.board_count} tree=#{tree_display} model=#{state.config.model} [#{build_display}]#{pending}\n" <>
      "#{state.mode} | i: type | Esc: commands | q: quit | #{state.status_message || ""}"
  end

  defp build_state_display(:idle), do: "idle"
  defp build_state_display(:building), do: "building…"
  defp build_state_display(:timed_out), do: "timed out"
  defp build_state_display({:exit, 0}), do: "exit 0"
  defp build_state_display({:exit, n}), do: "exit #{n}"
  defp build_state_display(:no_toolchain), do: "no toolchain"
end
