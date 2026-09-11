defmodule Hatch.KB.LoaderTest do
  use ExUnit.Case

  alias Hatch.KB.Loader
  alias Hatch.KB.Board

  setup do
    fixtures = Path.expand("../../fixtures", __DIR__)
    {:ok, fixtures: fixtures}
  end

  describe "load/1" do
    test "loads a board from board.toml", %{fixtures: fixtures} do
      board_toml = Path.join([fixtures, "kb_good", "boards", "mk1", "board.toml"])
      {:ok, board, warnings} = Loader.load(board_toml)

      assert board.id == "mk1"
      assert board.soc == "imx6ul"
      assert board.soc_key == "imx6ul"
      assert board.goarch == "arm"
      assert board.goarm == "7"
      assert board.ram_start == 2_147_483_648
      assert board.ram_size == 536_870_912
      assert board.uart == "UART2"
      assert "uart" in board.peripherals
      assert "gpio" in board.peripherals
      assert "usb" in board.peripherals
      assert warnings == []
    end

    test "sets unknown fields for absent fields", %{fixtures: fixtures} do
      board_toml = Path.join([fixtures, "kb_good", "boards", "mk2", "board.toml"])
      {:ok, board, warnings} = Loader.load(board_toml)

      assert board.id == "mk2"
      assert board.soc == "imx6ul"
      assert board.goarch == :unknown
      assert board.goarm == :unknown
      assert board.ram_start == :unknown
      assert board.ram_size == :unknown
      assert board.uart == :unknown
      assert board.peripherals == []
      assert board.pinmux == []
    end

    test "returns error for malformed TOML", %{fixtures: fixtures} do
      board_toml = Path.join([fixtures, "kb_broken", "boards", "bad_toml", "board.toml"])
      {:error, err} = Loader.load(board_toml)
      assert err.code == :invalid_args
    end
  end

  describe "load_all/1" do
    test "loads all boards except _example", %{fixtures: fixtures} do
      kb_root = Path.join(fixtures, "kb_good")
      {:ok, boards, warnings} = Loader.load_all(kb_root)

      assert length(boards) == 2
      assert Enum.any?(boards, &(&1.id == "mk1"))
      assert Enum.any?(boards, &(&1.id == "mk2"))
    end

    test "skips directories starting with underscore", %{fixtures: fixtures} do
      kb_root = Path.join(fixtures, "kb_good")
      {:ok, boards, _warnings} = Loader.load_all(kb_root)

      refute Enum.any?(boards, &(&1.id == "_example"))
    end

    test "returns warnings for bad boards but continues", %{fixtures: fixtures} do
      kb_root = Path.join(fixtures, "kb_broken")
      {:ok, boards, warnings} = Loader.load_all(kb_root)

      # Should still have the good board
      assert length(boards) == 1
      assert Enum.any?(boards, &(&1.id == "good"))

      # Should have warning for bad_toml
      assert Enum.any?(warnings, &(&1.board_id == "bad_toml"))
    end

    test "parses hex ram_start values", %{fixtures: fixtures} do
      kb_root = Path.join(fixtures, "kb_various")
      {:ok, boards, _warnings} = Loader.load_all(kb_root)

      board = Enum.find(boards, &(&1.id == "hex_values"))
      assert board.ram_start == 2_147_483_648
      assert board.ram_size == 536_870_912
    end

    test "normalizes peripherals", %{fixtures: fixtures} do
      kb_root = Path.join(fixtures, "kb_various")
      {:ok, boards, _warnings} = Loader.load_all(kb_root)

      board = Enum.find(boards, &(&1.id == "hex_values"))
      assert board.peripherals == ["gpio", "usb"]
    end

    test "handles invalid field values with warnings", %{fixtures: fixtures} do
      kb_root = Path.join(fixtures, "kb_various")
      {:ok, boards, warnings} = Loader.load_all(kb_root)

      board = Enum.find(boards, &(&1.id == "bad_fields"))
      assert board.ram_start == :unknown
      assert board.goarch == :unknown
      assert board.goarm == :unknown
      assert board.peripherals == []

      bad_field_warnings = Enum.filter(warnings, &(&1.board_id == "bad_fields"))
      assert length(bad_field_warnings) >= 4
    end

    test "warns about unknown keys", %{fixtures: fixtures} do
      kb_root = Path.join(fixtures, "kb_various")
      {:ok, _boards, warnings} = Loader.load_all(kb_root)

      board_warnings = Enum.filter(warnings, &(&1.board_id == "bad_fields"))
      assert Enum.any?(board_warnings, &String.contains?(&1.message, "Unknown key"))
    end

    test "soc normalization", %{fixtures: fixtures} do
      kb_root = Path.join(fixtures, "kb_various")
      {:ok, boards, _warnings} = Loader.load_all(kb_root)

      # All boards have imx6ul which should normalize to imx6ul
      boards
      |> Enum.filter(&(&1.soc_key != :unknown))
      |> Enum.each(fn board ->
        assert board.soc_key == "imx6ul"
      end)
    end
  end
end
