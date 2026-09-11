defmodule Hatch.BoardJob.Supervisor do
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

    with {:ok, pid} <- DynamicSupervisor.start_child(Hatch.BoardJob.DynamicSupervisor, child_spec) do
      {:ok, session_id, pid}
    end
  end

  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    Supervisor.start_link(__MODULE__, opts,
      name: {:via, Registry, {Hatch.Registry, {:board_job, session_id}}}
    )
  end

  @spec get_proposal_store(pid()) :: :ets.tid()
  def get_proposal_store(supervisor_pid) do
    case Supervisor.which_children(supervisor_pid) do
      [{Hatch.Proposal.StoreOwner, pid, :worker, _modules}] when is_pid(pid) ->
        Hatch.Proposal.StoreOwner.get_table(pid)

      [] ->
        # Table not yet created, create it lazily
        Hatch.Proposal.Store.new()

      _other ->
        # Unexpected state, create one
        Hatch.Proposal.Store.new()
    end
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    # Get config from opts or from persistent_term
    config = Keyword.get(opts, :config) || Hatch.Config.get()

    children = [
      {Task.Supervisor, name: {:via, Registry, {Hatch.Registry, {:task_supervisor, session_id}}}},
      {Hatch.Proposal.StoreOwner, []},
      {Hatch.Session,
       [
         session_id: session_id,
         config: config,
         task_supervisor: {:via, Registry, {Hatch.Registry, {:task_supervisor, session_id}}}
       ]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp generate_session_id do
    "s_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
