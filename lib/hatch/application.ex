defmodule Hatch.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Hatch.PubSub},
      {Registry, keys: :unique, name: Hatch.Registry},
      {Hatch.KB.Index, []},
      {DynamicSupervisor, name: Hatch.BoardJob.DynamicSupervisor, strategy: :one_for_one}
    ]

    opts = [strategy: :one_for_all, name: Hatch.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
