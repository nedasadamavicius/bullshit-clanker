defmodule Hatch.Acceptance.FixtureTest do
  use ExUnit.Case, async: false

  alias Hatch.Acceptance.Fixture
  alias Hatch.KB.Loader

  @moduletag :acceptance

  test "fixture KB has three imx6ul boards plus one off-SoC board" do
    {:ok, boards, _warnings} = Loader.load_all(Fixture.kb_path())
    ids = Enum.map(boards, & &1.id) |> Enum.sort()

    assert Fixture.held_out_id() in ids
    assert Fixture.off_soc_id() in ids
    assert "imx6ul_board_a" in ids
    assert "imx6ul_board_b" in ids

    imx6ul = Enum.filter(boards, &(&1.soc == "imx6ul"))
    assert length(imx6ul) == 3

    off = Enum.find(boards, &(&1.id == Fixture.off_soc_id()))
    assert off.soc == "imx8m"
  end

  test "held-out spec is markdown prose with two facts absent" do
    spec = File.read!(Fixture.spec_path())
    refute spec =~ ~r/^\s*id\s*=/m
    assert spec =~ "i.MX6UL"
    assert spec =~ "0x80000000"
    assert spec =~ "UART1"
    refute spec =~ "ram_size"
    refute spec =~ "tamago_board"
  end

  test "working tree is a copy of the nearest board overlay" do
    tree_go = File.read!(Path.join(Fixture.tree_path(), "board/fsl/board_a/board.go"))

    kb_go =
      File.read!(
        Path.join(Fixture.kb_path(), "boards/imx6ul_board_a/tree/board/fsl/board_a/board.go")
      )

    assert tree_go == kb_go
    assert File.exists?(Path.join(Fixture.tree_path(), "go.mod"))
  end

  test "prepare_tree copies to scratch and does not mutate the fixture" do
    before = Fixture.tree_hash(Fixture.tree_path())
    scratch = Fixture.prepare_tree()
    File.write!(Path.join(scratch, "mutated.txt"), "x")
    after_hash = Fixture.tree_hash(Fixture.tree_path())
    assert before == after_hash
    File.rm_rf!(scratch)
  end
end
