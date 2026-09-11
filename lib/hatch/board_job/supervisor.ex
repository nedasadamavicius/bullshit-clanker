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

  @impl true
  def init(_opts) do
    children = []
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp generate_session_id do
    "s_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
