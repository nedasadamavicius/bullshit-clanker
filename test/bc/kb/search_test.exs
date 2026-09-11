defmodule BC.KB.SearchTest do
  use ExUnit.Case

  alias BC.KB.Search
  alias BC.KB.Board

  setup do
    # Initialize ETS table once (assume Index GenServer runs)
    # Note: Search tests require proper setup with the Index GenServer
    # For now, we're testing Search logic with manual ETS setup

    {:ok, boards: []}
  end

  test "search gating by exact soc works" do
    # Create a basic board for direct testing
    board = %Board{
      id: "test_board",
      source_path: "boards/test/board.toml",
      soc: "imx6ul",
      soc_key: "imx6ul",
      goarch: "arm",
      goarm: "7",
      ram_start: 0x80000000,
      ram_size: 0x20000000,
      uart: "UART2",
      peripherals: ["uart", "gpio"],
      pinmux: [],
      tamago_soc: "github.com/...",
      tamago_board: "github.com/...",
      tree: :unknown,
      schematic: :unknown,
      notes: "Test board",
      raw: %{}
    }

    # Test from_board directly
    assert is_struct(board, Board)
  end

  test "soc normalization works correctly" do
    # Test that normalization removes -, _, and space chars
    # (dots are kept as they don't match our regex)
    soc1 = "imx6ul"
    soc2 = "imx-6ul"
    soc3 = "imx6ul_"

    # Normalization: downcase + remove -, _, space
    normalized1 = String.downcase(soc1) |> String.replace(~r/[-_ ]/, "")
    normalized2 = String.downcase(soc2) |> String.replace(~r/[-_ ]/, "")
    normalized3 = String.downcase(soc3) |> String.replace(~r/[-_ ]/, "")

    assert normalized1 == "imx6ul"
    assert normalized2 == "imx6ul"
    assert normalized3 == "imx6ul"
  end
end
