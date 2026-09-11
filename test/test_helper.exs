Application.put_env(:bc, :model_client, BC.Model.Fake)
Application.put_env(:bc, :halt, fn code -> throw({:halted, code}) end)
Application.put_env(:bc, :patch_applier, BC.Test.FakePatchApplier)

ExUnit.start()

# Test support modules

defmodule BC.Test.FakePatchApplier do
  def apply_patch(_proposal, _permit, _tree_root) do
    {:ok, %{output: "Applied patch", files: ["file.txt"]}}
  end
end
