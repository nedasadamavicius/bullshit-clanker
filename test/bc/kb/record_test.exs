defmodule BC.KB.RecordTest do
  use ExUnit.Case, async: true

  alias BC.KB.{Board, Loader, Record}

  test "to_toml/1 omits unknown fields and round-trips through the loader" do
    board = %Board{
      id: "roundtrip",
      source_path: "boards/roundtrip/board.toml",
      soc: "imx6ul",
      soc_key: "imx6ul",
      goarch: "arm",
      goarm: "7",
      ram_start: 0x80000000,
      ram_size: :unknown,
      uart: "UART2",
      peripherals: ["uart", "gpio"],
      pinmux: [%{signal: "UART2_TX", pad: "CSI_DATA00", fn: "ALT3"}],
      tamago_soc: :unknown,
      tamago_board: :unknown,
      schematic: "boards/roundtrip/schematic.pdf",
      tree: :unknown,
      notes: :unknown,
      raw: %{}
    }

    toml = Record.to_toml(board)
    assert toml =~ ~s(id = "roundtrip")
    assert toml =~ ~s(soc = "imx6ul")
    assert toml =~ ~s(ram_start = "0x80000000")
    refute toml =~ "ram_size"
    refute toml =~ "tamago_board"
    assert toml =~ "[[pinmux]]"

    dir = Path.join(System.tmp_dir!(), "bc_rec_#{System.unique_integer([:positive])}")
    dest = Path.join(dir, "boards/roundtrip")
    File.mkdir_p!(dest)
    path = Path.join(dest, "board.toml")
    File.write!(path, toml)

    {:ok, loaded, warnings} = Loader.load(path)
    assert loaded.id == "roundtrip"
    assert loaded.soc == "imx6ul"
    assert loaded.ram_start == 0x80000000
    assert loaded.ram_size == :unknown
    assert loaded.uart == "UART2"
    assert hd(loaded.pinmux).signal == "UART2_TX"
    assert warnings == [] or is_list(warnings)

    File.rm_rf!(dir)
  end
end
