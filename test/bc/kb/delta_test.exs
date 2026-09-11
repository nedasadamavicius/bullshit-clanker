defmodule BC.KB.DeltaTest do
  use ExUnit.Case

  alias BC.KB.Delta
  alias BC.KB.Board

  test "compare same values" do
    draft = %Board{
      id: "draft",
      source_path: "draft.toml",
      soc: "imx6ul",
      soc_key: "imx6ul",
      goarch: "arm",
      goarm: "7",
      ram_start: 0x80000000,
      ram_size: 0x20000000,
      uart: "UART2",
      peripherals: ["gpio", "uart"],
      pinmux: [],
      tamago_soc: "github.com/...",
      tamago_board: "github.com/...",
      tree: :unknown,
      schematic: :unknown,
      notes: :unknown,
      raw: %{}
    }

    board = draft

    deltas = Delta.compare(draft, board)

    # All fields should be :same
    Enum.each(deltas, fn delta ->
      assert delta.kind == :same, "Expected :same for field #{delta.field}, got #{delta.kind}"
    end)
  end

  test "compare unknown in draft" do
    draft = %Board{
      id: "draft",
      source_path: "draft.toml",
      soc: :unknown,
      soc_key: :unknown,
      goarch: :unknown,
      goarm: :unknown,
      ram_start: :unknown,
      ram_size: :unknown,
      uart: :unknown,
      peripherals: [],
      pinmux: [],
      tamago_soc: :unknown,
      tamago_board: :unknown,
      tree: :unknown,
      schematic: :unknown,
      notes: :unknown,
      raw: %{}
    }

    board = %Board{
      id: "board",
      source_path: "board.toml",
      soc: "imx6ul",
      soc_key: "imx6ul",
      goarch: "arm",
      goarm: "7",
      ram_start: 0x80000000,
      ram_size: 0x20000000,
      uart: "UART2",
      peripherals: ["gpio", "uart"],
      pinmux: [],
      tamago_soc: "github.com/...",
      tamago_board: "github.com/...",
      tree: "tree/path",
      schematic: :unknown,
      notes: :unknown,
      raw: %{}
    }

    deltas = Delta.compare(draft, board)

    # Check specific fields
    soc_delta = Enum.find(deltas, &(&1.field == :soc))
    assert soc_delta.kind == :unknown_in_draft

    uart_delta = Enum.find(deltas, &(&1.field == :uart))
    assert uart_delta.kind == :unknown_in_draft
  end

  test "compare differs" do
    draft = %Board{
      id: "draft",
      source_path: "draft.toml",
      soc: "imx6ul",
      soc_key: "imx6ul",
      goarch: "arm",
      goarm: "7",
      ram_start: 0x80000000,
      ram_size: 0x20000000,
      uart: "UART2",
      peripherals: ["gpio"],
      pinmux: [],
      tamago_soc: "github.com/...",
      tamago_board: "github.com/...",
      tree: :unknown,
      schematic: :unknown,
      notes: :unknown,
      raw: %{}
    }

    board = %Board{
      id: "board",
      source_path: "board.toml",
      soc: "imx6ul",
      soc_key: "imx6ul",
      goarch: "arm64",
      goarm: "7",
      ram_start: 0x80000000,
      ram_size: 0x40000000,
      uart: "UART3",
      peripherals: ["gpio", "uart"],
      pinmux: [],
      tamago_soc: "github.com/...",
      tamago_board: "github.com/...",
      tree: :unknown,
      schematic: :unknown,
      notes: :unknown,
      raw: %{}
    }

    deltas = Delta.compare(draft, board)

    # Check fields that differ
    goarch_delta = Enum.find(deltas, &(&1.field == :goarch))
    assert goarch_delta.kind == :differs

    uart_delta = Enum.find(deltas, &(&1.field == :uart))
    assert uart_delta.kind == :differs

    ram_size_delta = Enum.find(deltas, &(&1.field == :ram_size))
    assert ram_size_delta.kind == :differs

    # Peripherals differ as sets
    periph_delta = Enum.find(deltas, &(&1.field == :peripherals))
    assert periph_delta.kind == :differs
  end

  test "render deltas" do
    deltas = [
      %Delta{field: :soc, draft: "imx6ul", board: "imx6ul", kind: :same},
      %Delta{field: :uart, draft: "UART2", board: "UART3", kind: :differs},
      %Delta{field: :ram_size, draft: :unknown, board: 0x20000000, kind: :unknown_in_draft}
    ]

    output = Delta.render(deltas)

    assert String.contains?(output, "soc: imx6ul")
    assert String.contains?(output, "uart: UART2 → UART3")
    assert String.contains?(output, "ram_size: unknown (draft) vs 0x20000000")
  end
end
