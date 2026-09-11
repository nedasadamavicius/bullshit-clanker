defmodule BC.Session do
  @moduledoc """
  Session GenServer: transcript, tool loop, event broadcasting.

  Child of BC.BoardJob.Supervisor, registered as
  {:via, Registry, {BC.Registry, {:session, session_id}}}.

  One session process per conversational turn; no write token held.
  Enforces I7 (one session talks to user) and I5 (citation checks in prompt).
  """

  use GenServer
  require Logger

  alias BC.Events
  alias BC.KB.Board
  alias BC.Model
  alias BC.Session.Prompt
  alias BC.Session.Transcript
  alias BC.Tools
  alias BC.Tools.ReadLog

  @max_steps 12

  # --- Supervision ---

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {BC.Registry, {:session, session_id}}}
    )
  end

  # --- Public API ---

  @spec send_message(String.t(), String.t()) :: :ok
  def send_message(session_id, text) do
    GenServer.cast(via_tuple(session_id), {:send_message, text})
  end

  @spec cancel(String.t()) :: :ok
  def cancel(session_id) do
    GenServer.call(via_tuple(session_id), :cancel)
  end

  @spec transcript(String.t()) :: [Model.message()]
  def transcript(session_id) do
    GenServer.call(via_tuple(session_id), :get_transcript)
  end

  @spec set_draft(String.t(), Board.t()) :: :ok
  def set_draft(session_id, draft) do
    GenServer.call(via_tuple(session_id), {:set_draft, draft})
  end

  @spec usage(String.t()) :: map()
  def usage(session_id) do
    GenServer.call(via_tuple(session_id), :get_usage)
  end

  @spec note_applied(String.t(), any(), [String.t()]) :: :ok
  def note_applied(session_id, _proposal, _output) do
    GenServer.cast(via_tuple(session_id), :note_applied)
  end

  @spec note_rejected(String.t(), any(), String.t() | nil) :: :ok
  def note_rejected(session_id, _proposal, _reason) do
    GenServer.cast(via_tuple(session_id), :note_rejected)
  end

  @spec note_build(String.t(), map()) :: :ok
  def note_build(session_id, _build_info) do
    GenServer.cast(via_tuple(session_id), :note_build)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    config = Keyword.fetch!(opts, :config)
    task_supervisor = Keyword.fetch!(opts, :task_supervisor)

    read_log = ReadLog.new()
    proposal_store = lookup_proposal_store(session_id)
    system_prompt = Prompt.system(config, nil)

    state = %{
      session_id: session_id,
      config: config,
      messages: [
        %{
          role: :system,
          content: system_prompt,
          tool_calls: nil,
          tool_call_id: nil
        }
      ],
      read_log: read_log,
      proposal_store: proposal_store,
      draft: nil,
      usage: %{},
      turn: nil,
      cancelled?: false,
      task_supervisor: task_supervisor
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:send_message, text}, state) do
    # Start turn in a Task
    case start_turn_task(state, text) do
      {:ok, new_state} ->
        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("Failed to start turn: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast(:note_applied, state) do
    {:noreply, state}
  end

  def handle_cast(:note_rejected, state) do
    {:noreply, state}
  end

  def handle_cast(:note_build, state) do
    {:noreply, state}
  end

  def handle_cast({:add_usage, usage}, state) when is_map(usage) do
    {:noreply, %{state | usage: merge_usage(state.usage, usage)}}
  end

  def handle_cast({:add_usage, _}, state), do: {:noreply, state}

  @impl true
  def handle_call({:set_draft, draft}, _from, state) do
    system_prompt = Prompt.system(state.config, draft)

    new_messages = [
      %{
        role: :system,
        content: system_prompt,
        tool_calls: nil,
        tool_call_id: nil
      }
      | Enum.drop(state.messages, 1)
    ]

    {:reply, :ok, %{state | draft: draft, messages: new_messages}}
  end

  def handle_call(:cancel, _from, state) do
    # Mark as cancelled and signal any running task
    new_state = %{state | cancelled?: true}

    # If there's a running turn, kill the task
    final_state =
      if state.turn do
        cancel_turn(new_state)
      else
        new_state
      end

    {:reply, :ok, final_state}
  end

  def handle_call(:get_transcript, _from, state) do
    {:reply, state.messages, state}
  end

  def handle_call(:get_usage, _from, state) do
    {:reply, state.usage || %{}, state}
  end

  def handle_call(:is_cancelled?, _from, state) do
    {:reply, state.cancelled?, state}
  end

  @impl true
  def handle_info({ref, {:turn, messages, reason}}, state) when is_reference(ref) do
    case state.turn do
      %{task: %Task{ref: ^ref}} ->
        new_state = %{state | messages: messages, turn: nil, cancelled?: false}
        Events.broadcast(state.session_id, %{type: :turn_finished, reason: reason})
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) and is_list(result) do
    handle_info({ref, {:turn, result, :ok}}, state)
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    # Task crashed or was killed
    if state.turn do
      Logger.warn("Turn task died: #{inspect(reason)}")
      {:noreply, %{state | turn: nil, cancelled?: false}}
    else
      {:noreply, state}
    end
  end

  # --- Turn loop ---

  defp start_turn_task(state, user_text) do
    task_supervisor = state.task_supervisor
    session_id = state.session_id

    # Append user message
    user_msg = %{
      role: :user,
      content: user_text,
      tool_calls: nil,
      tool_call_id: nil
    }

    new_messages = Transcript.append(state.messages, user_msg)
    Events.broadcast(session_id, %{type: :user_message, text: user_text})

    # Start turn task
    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        run_turn(
          state.session_id,
          state.config,
          new_messages,
          state.read_log,
          state.draft,
          state.proposal_store,
          1
        )
      end)

    {:ok,
     %{
       state
       | messages: new_messages,
         turn: %{task: task, step: 1}
     }}
  end

  defp run_turn(session_id, _config, messages, _read_log, _draft, _proposal_store, step)
       when step > @max_steps do
    # Max steps reached, mark as done
    system_note = %{
      role: :system,
      content: "Step limit (#{@max_steps}) reached. Wrapping up.",
      tool_calls: nil,
      tool_call_id: nil
    }

    bounded = Transcript.bound([system_note | messages], nil)
    {:turn, bounded, :max_steps}
  end

  defp run_turn(session_id, config, messages, read_log, draft, proposal_store, step) do
    model_client = Application.get_env(:bc, :model_client, BC.Model.OpenAI)

    tool_ctx = %{
      session_id: session_id,
      read_log: read_log,
      proposal_store: proposal_store,
      kb_root: config.kb_root,
      tree_root: config.tree_root,
      draft: draft
    }

    case model_client.chat(
           messages,
           [model: config.model, tools: Tools.schemas(config)],
           fn chunk -> handle_model_chunk(chunk, session_id) end
         ) do
      {:ok, result} ->
        handle_model_result(
          session_id,
          config,
          messages,
          read_log,
          draft,
          step,
          result,
          tool_ctx
        )

      {:error, err} ->
        Events.broadcast(session_id, %{
          type: :error,
          stage: :model,
          message: err.message
        })

        {:turn, messages, :error}
    end
  end

  defp handle_model_chunk({:text, text}, session_id) do
    Events.broadcast(session_id, %{type: :assistant_delta, text: text})
  end

  defp handle_model_chunk({:tool_call, _tool_call}, _session_id) do
    # Tool call will be handled in handle_model_result
    :ok
  end

  defp handle_model_chunk({:done, _}, _session_id) do
    :ok
  end

  defp handle_model_result(session_id, config, messages, read_log, draft, step, result, tool_ctx) do
    record_usage(session_id, Map.get(result, :usage))

    assistant_msg = %{
      role: :assistant,
      content: result.text,
      tool_calls: if(Enum.empty?(result.tool_calls), do: nil, else: result.tool_calls),
      tool_call_id: nil
    }

    messages_with_assistant = Transcript.append(messages, assistant_msg)

    case result.tool_calls do
      [] ->
        bounded = Transcript.bound(messages_with_assistant, nil)

        Events.broadcast(session_id, %{
          type: :assistant_message,
          text: result.text
        })

        {:turn, bounded, :ok}

      tool_calls ->
        case process_tool_calls(
               session_id,
               config,
               messages_with_assistant,
               read_log,
               tool_calls,
               tool_ctx
             ) do
          {:continue, messages_after_tools} ->
            run_turn(
              session_id,
              config,
              messages_after_tools,
              read_log,
              draft,
              tool_ctx.proposal_store,
              step + 1
            )

          {:cancelled, messages_with_cancellation} ->
            bounded = Transcript.bound(messages_with_cancellation, nil)
            {:turn, bounded, :cancelled}
        end
    end
  end

  defp process_tool_calls(session_id, _config, messages, _read_log, tool_calls, tool_ctx) do
    Enum.reduce_while(
      tool_calls,
      {:continue, messages},
      fn tool_call, {:continue, acc_messages} ->
        if should_cancel?(session_id) do
          # Synthesize cancelled results for remaining tools
          messages_with_cancellation =
            synthesize_tool_results(acc_messages, tool_calls, tool_call.id)

          {:halt, {:cancelled, messages_with_cancellation}}
        else
          case process_single_tool_call(session_id, tool_call, acc_messages, tool_ctx) do
            {:ok, messages_with_result} ->
              {:cont, {:continue, messages_with_result}}

            {:cancelled, messages_with_result} ->
              # Synthesize results for remaining tools
              remaining_calls = Enum.drop_while(tool_calls, &(&1.id != tool_call.id))

              messages_with_all_results =
                synthesize_remaining_tool_results(messages_with_result, remaining_calls)

              {:halt, {:cancelled, messages_with_all_results}}
          end
        end
      end
    )
  end

  defp process_single_tool_call(session_id, tool_call, messages, tool_ctx) do
    start_time = System.monotonic_time(:millisecond)

    Events.broadcast(session_id, %{
      type: :tool_call_started,
      call_id: tool_call.id,
      name: tool_call.name,
      args: tool_call.arguments
    })

    case do_call_tool(tool_call.name, tool_call.arguments, tool_ctx) do
      {:ok, result} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.broadcast(session_id, %{
          type: :tool_call_finished,
          call_id: tool_call.id,
          name: tool_call.name,
          ok: true,
          summary: summary_from_result(result),
          duration_ms: duration
        })

        tool_msg = %{
          role: :tool,
          content: result,
          tool_calls: nil,
          tool_call_id: tool_call.id
        }

        {:ok, Transcript.append(messages, tool_msg)}

      {:error, err} ->
        duration = System.monotonic_time(:millisecond) - start_time
        error_json = Jason.encode!(%{error: err})

        Events.broadcast(session_id, %{
          type: :tool_call_finished,
          call_id: tool_call.id,
          name: tool_call.name,
          ok: false,
          summary: "error: #{err.code}",
          duration_ms: duration
        })

        tool_msg = %{
          role: :tool,
          content: error_json,
          tool_calls: nil,
          tool_call_id: tool_call.id
        }

        {:ok, Transcript.append(messages, tool_msg)}

      {:crashed, error_msg} ->
        duration = System.monotonic_time(:millisecond) - start_time

        Events.broadcast(session_id, %{
          type: :tool_call_finished,
          call_id: tool_call.id,
          name: tool_call.name,
          ok: false,
          summary: "crashed: #{error_msg}",
          duration_ms: duration
        })

        tool_msg = %{
          role: :tool,
          content: Jason.encode!(%{error: %{code: :tool_crashed, message: error_msg}}),
          tool_calls: nil,
          tool_call_id: tool_call.id
        }

        {:ok, Transcript.append(messages, tool_msg)}
    end
  end

  defp do_call_tool(tool_name, tool_args, tool_ctx) do
    case Tools.call(tool_name, tool_args, tool_ctx) do
      result when is_tuple(result) and elem(result, 0) in [:ok, :error] ->
        result

      other ->
        {:error, %{code: :internal_error, message: "unexpected result: #{inspect(other)}"}}
    end
  rescue
    e ->
      {:crashed, Exception.message(e)}
  end

  defp should_cancel?(session_id) do
    case Registry.lookup(BC.Registry, {:session, session_id}) do
      [{pid, nil}] ->
        GenServer.call(pid, :is_cancelled?)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp synthesize_tool_results(messages, tool_calls, from_id) do
    # Find the position of the tool call we're at
    remaining_calls =
      Enum.drop_while(tool_calls, &(&1.id != from_id))
      |> Enum.drop(1)

    synthesize_remaining_tool_results(messages, remaining_calls)
  end

  defp synthesize_remaining_tool_results(messages, tool_calls) do
    Enum.reduce(tool_calls, messages, fn tool_call, acc_messages ->
      cancelled_result = Jason.encode!(%{error: %{code: :cancelled}})

      tool_msg = %{
        role: :tool,
        content: cancelled_result,
        tool_calls: nil,
        tool_call_id: tool_call.id
      }

      Transcript.append(acc_messages, tool_msg)
    end)
  end

  defp cancel_turn(state) do
    if state.turn && state.turn.task do
      Task.shutdown(state.turn.task, :kill)

      system_note = %{
        role: :system,
        content: "Turn cancelled by operator.",
        tool_calls: nil,
        tool_call_id: nil
      }

      messages_with_note = Transcript.append(state.messages, system_note)
      bounded = Transcript.bound(messages_with_note, nil)

      Events.broadcast(state.session_id, %{type: :turn_finished, reason: :cancelled})

      %{state | messages: bounded, turn: nil}
    else
      state
    end
  end

  defp summary_from_result(result) do
    # First line only, max 80 chars
    result
    |> String.split("\n")
    |> Enum.at(0)
    |> String.slice(0..79)
  end

  defp via_tuple(session_id) do
    {:via, Registry, {BC.Registry, {:session, session_id}}}
  end

  defp lookup_proposal_store(session_id) do
    case Registry.lookup(BC.Registry, {:proposal_store, session_id}) do
      [{pid, _}] -> BC.Proposal.StoreOwner.get_table(pid)
      [] -> BC.Proposal.Store.new()
    end
  end

  defp record_usage(session_id, usage) when is_map(usage) and map_size(usage) > 0 do
    GenServer.cast(via_tuple(session_id), {:add_usage, usage})
  end

  defp record_usage(_session_id, _), do: :ok

  defp merge_usage(a, b) when is_map(a) and is_map(b) do
    Map.merge(a, b, fn _k, v1, v2 ->
      cond do
        is_integer(v1) and is_integer(v2) -> v1 + v2
        true -> v2
      end
    end)
  end

  defp merge_usage(_, b) when is_map(b), do: b
  defp merge_usage(a, _), do: a
end
