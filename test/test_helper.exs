Application.put_env(:hatch, :model_client, Hatch.Model.Fake)
Application.put_env(:hatch, :halt, fn code -> throw({:halted, code}) end)
Application.put_env(:hatch, :patch_applier, Hatch.Test.FakePatchApplier)

ExUnit.start()

# Test support modules

defmodule Hatch.Test.FakePatchApplier do
  def apply_patch(_proposal, _permit, _tree_root) do
    {:ok, %{output: "Applied patch", files: ["file.txt"]}}
  end
end
