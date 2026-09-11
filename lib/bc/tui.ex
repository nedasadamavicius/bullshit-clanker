defmodule BC.TUI do
  @moduledoc """
  TUI for BC using raw ANSI rendering (fallback for when Ratatouille cannot build).

  Handles event subscription, layout, and interaction with the session.
  """

  require Logger

  alias BC.Events
  alias BC.TUI.Model

  @spec run(String.t(), BC.Config.t(), non_neg_integer()) :: :ok
  def run(session_id, config, board_count) do
    # Find the board job supervisor
    {:ok, board_job_supervisor} = find_board_job_supervisor(session_id)
    session_pid = find_session_pid(session_id)

    # Initial model
    initial_model = Model.init(session_id, config, board_count, session_pid)

    # Subscribe to events
    :ok = Events.subscribe(session_id)

    # Monitor session process
    if session_pid do
      Process.monitor(session_pid)
    end

    # Monitor board job supervisor
    Process.monitor(board_job_supervisor)

    # Spawn a task to read keyboard input from stdin
    self_pid = self()
    _stdin_reader_pid = spawn_link(fn -> read_stdin_loop(self_pid) end)

    # Run the event loop
    _final_state = run_event_loop(initial_model, board_job_supervisor)

    # Clean up: terminate the supervisor
    terminate_supervisor(board_job_supervisor)

    :ok
  rescue
    e ->
      Logger.error("TUI crashed: #{Exception.message(e)}")
      reraise e, __STACKTRACE__
  end

  defp terminate_supervisor(supervisor_pid) do
    case DynamicSupervisor.terminate_child(BC.BoardJob.DynamicSupervisor, supervisor_pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> Logger.warn("Failed to terminate supervisor: #{inspect(reason)}")
    end
  end

  defp run_event_loop(model, board_job_supervisor) do
    receive do
      {:bc_event, _event} = bc_event ->
        new_model = Model.update(model, bc_event)

        case new_model do
          {:quit, state} -> state
          state -> run_event_loop(state, board_job_supervisor)
        end

      {:key, _key} = key_event ->
        new_model = Model.update(model, key_event)

        case new_model do
          {:quit, state} -> state
          state -> run_event_loop(state, board_job_supervisor)
        end

      {:stdin_eof} ->
        model

      {:DOWN, _ref, :process, _pid, _reason} = down ->
        new_model = Model.update(model, down)
        run_event_loop(new_model, board_job_supervisor)

      _ ->
        run_event_loop(model, board_job_supervisor)
    after
      100 ->
        run_event_loop(model, board_job_supervisor)
    end
  end

  defp find_board_job_supervisor(session_id) do
    case Registry.lookup(BC.Registry, {:board_job, session_id}) do
      [{pid, nil}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp find_session_pid(session_id) do
    case Registry.lookup(BC.Registry, {:session, session_id}) do
      [{pid, nil}] -> pid
      [] -> nil
    end
  end

  defp read_stdin_loop(main_pid) do
    case IO.read(:stdio, 1) do
      :eof ->
        # Send EOF signal to the main loop
        send(main_pid, {:stdin_eof})

      "" ->
        # Empty read, treat as EOF
        send(main_pid, {:stdin_eof})

      char ->
        # Parse the character into a key event
        case parse_key(char) do
          {:key, key} ->
            send(main_pid, {:key, key})

          :skip ->
            :ok
        end

        # Continue reading
        read_stdin_loop(main_pid)
    end
  end

  defp parse_key(char) do
    case char do
      "\n" -> {:key, :enter}
      "\e" -> {:key, :esc}
      "\t" -> {:key, :tab}
      "\b" -> {:key, :backspace}
      "\x03" -> {:key, :"Ctrl+c"}
      "q" -> {:key, :char_q}
      "i" -> {:key, :char_i}
      "j" -> {:key, :char_j}
      "k" -> {:key, :char_k}
      "a" -> {:key, :char_a}
      "r" -> {:key, :char_r}
      "b" -> {:key, :char_b}
      "c" -> {:key, :char_c}
      "y" -> {:key, :char_y}
      # Note: PgUp/PgDn and arrow keys would need ANSI escape sequence parsing
      # which requires buffering multiple characters. For now, simple char handling.
      c when byte_size(c) == 1 -> {:key, String.to_charlist(c) |> hd()}
      _ -> :skip
    end
  end
end
