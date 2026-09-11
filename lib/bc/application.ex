defmodule BC.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: BC.PubSub},
      {Registry, keys: :unique, name: BC.Registry},
      {BC.KB.Index, []},
      {DynamicSupervisor, name: BC.BoardJob.DynamicSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_all, name: BC.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
