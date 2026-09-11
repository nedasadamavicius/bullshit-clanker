defmodule Hatch.TUI do
  @moduledoc """
  TUI for Hatch using raw ANSI rendering (fallback for when Ratatouille cannot build).

  Handles event subscription, layout, and interaction with the session.
  """

  require Logger

  alias Hatch.Events
  alias Hatch.TUI.Model

  @spec run(String.t(), Hatch.Config.t(), non_neg_integer()) :: :ok
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

    # Run the event loop
    run_event_loop(initial_model, board_job_supervisor)

    # Clean up: terminate the supervisor
    terminate_supervisor(board_job_supervisor)

    :ok
  rescue
    e ->
      Logger.error("TUI crashed: #{Exception.message(e)}")
      reraise e, __STACKTRACE__
  end

  defp terminate_supervisor(supervisor_pid) do
    case DynamicSupervisor.terminate_child(Hatch.BoardJob.DynamicSupervisor, supervisor_pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> Logger.warn("Failed to terminate supervisor: #{inspect(reason)}")
    end
  end

  defp run_event_loop(model, board_job_supervisor) do
    receive do
      {:hatch_event, _event} = hatch_event ->
        new_model = Model.update(model, hatch_event)
        run_event_loop(new_model, board_job_supervisor)

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
    case Registry.lookup(Hatch.Registry, {:board_job, session_id}) do
      [{pid, nil}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  defp find_session_pid(session_id) do
    case Registry.lookup(Hatch.Registry, {:session, session_id}) do
      [{pid, nil}] -> pid
      [] -> nil
    end
  end
end
