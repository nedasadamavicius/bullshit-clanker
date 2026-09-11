defmodule Hatch.Tools.Propose do
  @moduledoc """
  propose_patch tool - implemented in spec 008.

  Stub for now.
  """

  @spec propose(map(), Hatch.Tools.ctx()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def propose(_args, _ctx) do
    {:error, %{code: :not_implemented, message: "propose_patch is implemented in spec 008"}}
  end
end
