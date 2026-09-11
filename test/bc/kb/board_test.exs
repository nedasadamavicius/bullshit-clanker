defmodule BC.KB.BoardTest do
  use ExUnit.Case

  alias BC.KB.Board

  describe "known?/1" do
    test "returns false for :unknown" do
      assert Board.known?(:unknown) == false
    end

    test "returns false for empty list" do
      assert Board.known?([]) == false
    end

    test "returns true for other values" do
      assert Board.known?("imx6ul") == true
      assert Board.known?(123) == true
      assert Board.known?(["item"]) == true
    end
  end

  describe "fetch/2" do
    test "returns {:ok, value} for known fields" do
      board = %Board{id: "test", soc: "imx6ul", source_path: "boards/test/board.toml"}
      assert Board.fetch(board, :id) == {:ok, "test"}
      assert Board.fetch(board, :soc) == {:ok, "imx6ul"}
    end

    test "returns :unknown for unknown fields" do
      board = %Board{id: "test", soc: :unknown, source_path: "boards/test/board.toml"}
      assert Board.fetch(board, :soc) == :unknown
    end

    test "returns :unknown for empty list fields" do
      board = %Board{
        id: "test",
        peripherals: [],
        source_path: "boards/test/board.toml"
      }

      assert Board.fetch(board, :peripherals) == :unknown
    end
  end

  describe "to_facts/1" do
    test "includes the word 'unknown' for absent fields" do
      board = %Board{
        id: "test",
        source_path: "boards/test/board.toml",
        soc: "imx6ul",
        goarch: :unknown,
        goarm: :unknown,
        ram_start: :unknown,
        ram_size: :unknown,
        uart: :unknown,
        peripherals: [],
        pinmux: [],
        tamago_soc: :unknown,
        tamago_board: :unknown,
        schematic: :unknown,
        tree: :unknown,
        notes: :unknown,
        soc_key: "imx6ul"
      }

      facts = Board.to_facts(board)
      assert String.contains?(facts, "unknown")
      assert String.contains?(facts, "imx6ul")
    end

    test "renders hex numbers as 0x..." do
      board = %Board{
        id: "test",
        source_path: "boards/test/board.toml",
        soc: "imx6ul",
        ram_start: 2_147_483_648,
        ram_size: 536_870_912,
        goarch: :unknown,
        goarm: :unknown,
        uart: :unknown,
        peripherals: [],
        pinmux: [],
        tamago_soc: :unknown,
        tamago_board: :unknown,
        schematic: :unknown,
        tree: :unknown,
        notes: :unknown,
        soc_key: "imx6ul"
      }

      facts = Board.to_facts(board)
      assert String.contains?(facts, "0x80000000")
      assert String.contains?(facts, "0x20000000")
    end

    test "is deterministic across runs" do
      board = %Board{
        id: "test",
        source_path: "boards/test/board.toml",
        soc: "imx6ul",
        goarch: "arm",
        goarm: "7",
        ram_start: 2_147_483_648,
        ram_size: 536_870_912,
        uart: "UART2",
        peripherals: ["gpio", "uart"],
        pinmux: [%{signal: "UART2_TX", pad: "CSI_DATA00", fn: "ALT3"}],
        tamago_soc: "github.com/usbarmory/tamago/soc/nxp/imx6ul",
        tamago_board: "github.com/usbarmory/tamago/board/usbarmory/mk2",
        schematic: "schematic.pdf",
        tree: "tree",
        notes: "Test board",
        soc_key: "imx6ul"
      }

      facts1 = Board.to_facts(board)
      facts2 = Board.to_facts(board)
      assert facts1 == facts2
    end
  end
end
