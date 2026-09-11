defmodule BC.Proposal.StoreOwner do
  @moduledoc """
  Simple GenServer that owns the proposal store ETS table.

  The owner process is part of the session supervisor tree, so the table
  survives a session crash.
  """

  use GenServer

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    session_id = Keyword.get(opts, :session_id)

    name_opts =
      if is_binary(session_id) do
        [name: {:via, Registry, {BC.Registry, {:proposal_store, session_id}}}]
      else
        []
      end

    GenServer.start_link(__MODULE__, opts, name_opts)
  end

  @spec get_table(pid()) :: :ets.tid()
  def get_table(pid) do
    GenServer.call(pid, :get_table)
  end

  @impl true
  def init(_opts) do
    table = BC.Proposal.Store.new()
    {:ok, table}
  end

  @impl true
  def handle_call(:get_table, _from, table) do
    {:reply, table, table}
  end
end
