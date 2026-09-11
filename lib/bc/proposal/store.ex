defmodule BC.Proposal.Store do
  @moduledoc """
  ETS-backed proposal store (per-session).

  Survives a session crash so a pending patch is not lost.

  Table structure: {session_id, proposal_id, proposal}
  """

  @type t :: :ets.tid()

  @spec new() :: t()
  def new do
    :ets.new(:proposal_store, [:set, :public, {:keypos, 1}])
  end

  @spec put(t(), BC.Proposal.t()) :: :ok
  def put(tid, proposal) do
    # Store as {session_id_proposal_id, proposal}
    key = {proposal.session_id, proposal.id}
    :ets.insert(tid, {key, proposal})
    :ok
  end

  @spec pending(t(), String.t()) :: {:ok, BC.Proposal.t()} | :none
  def pending(tid, session_id) do
    case :ets.match_object(tid, {{session_id, :_}, :_}) do
      [] ->
        :none

      results ->
        # Find the :pending one
        case Enum.find(results, fn {_key, proposal} -> proposal.status == :pending end) do
          {_key, proposal} -> {:ok, proposal}
          nil -> :none
        end
    end
  end

  @spec get(t(), String.t(), String.t()) :: {:ok, BC.Proposal.t()} | {:error, :not_found}
  def get(tid, session_id, proposal_id) do
    key = {session_id, proposal_id}

    case :ets.lookup(tid, key) do
      [{^key, proposal}] -> {:ok, proposal}
      [] -> {:error, :not_found}
    end
  end

  @spec set_status(t(), String.t(), String.t(), :applied | :rejected | :invalid, [String.t()]) ::
          :ok
  def set_status(tid, session_id, proposal_id, status, reasons \\ []) do
    key = {session_id, proposal_id}

    case :ets.lookup(tid, key) do
      [{^key, proposal}] ->
        updated = %{proposal | status: status, invalid_reasons: reasons}
        :ets.insert(tid, {key, updated})
        :ok

      [] ->
        :ok
    end
  end
end
