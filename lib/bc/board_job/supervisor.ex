defmodule BC.BoardJob.Supervisor do
  @moduledoc false

  use Supervisor

  @spec start_session(keyword()) :: {:ok, session_id :: String.t(), pid()}
  def start_session(opts) do
    session_id = generate_session_id()

    child_spec = %{
      id: {:board_job, session_id},
      start: {__MODULE__, :start_link, [[session_id: session_id] ++ opts]},
      restart: :transient
    }

    with {:ok, pid} <- DynamicSupervisor.start_child(BC.BoardJob.DynamicSupervisor, child_spec) do
      {:ok, session_id, pid}
    end
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    Supervisor.start_link(__MODULE__, opts,
      name: {:via, Registry, {BC.Registry, {:board_job, session_id}}}
    )
  end

  @spec get_proposal_store(pid()) :: :ets.tid()
  def get_proposal_store(supervisor_pid) when is_pid(supervisor_pid) do
    children = Supervisor.which_children(supervisor_pid)

    case Enum.find(children, fn
           {BC.Proposal.StoreOwner, pid, :worker, _} when is_pid(pid) -> true
           _ -> false
         end) do
      {_, pid, _, _} -> BC.Proposal.StoreOwner.get_table(pid)
      nil -> BC.Proposal.Store.new()
    end
  end

  @spec get_proposal_store(String.t()) :: :ets.tid()
  def get_proposal_store(session_id) when is_binary(session_id) do
    case Registry.lookup(BC.Registry, {:proposal_store, session_id}) do
      [{pid, _}] -> BC.Proposal.StoreOwner.get_table(pid)
      [] -> BC.Proposal.Store.new()
    end
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    # Get config from opts or from persistent_term
    config = Keyword.get(opts, :config) || BC.Config.get()

    children = [
      {Task.Supervisor, name: {:via, Registry, {BC.Registry, {:task_supervisor, session_id}}}},
      {BC.Proposal.StoreOwner, [session_id: session_id]},
      {BC.Session,
       [
         session_id: session_id,
         config: config,
         task_supervisor: {:via, Registry, {BC.Registry, {:task_supervisor, session_id}}}
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp generate_session_id do
    "s_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
