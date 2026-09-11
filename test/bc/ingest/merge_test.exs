defmodule BC.Ingest.MergeTest do
  use ExUnit.Case

  alias BC.Ingest.Merge

  describe "merge/2" do
    test "merges single result with extracted fields" do
      results = [
        {:ok,
         %{
           "soc" => %{value: "i.MX6UL", evidence: "i.MX6UL"},
           "ram_start" => %{value: "0x80000000", evidence: "0x80000000"},
           "uart" => %{value: "UART2", evidence: "UART2"}
         }}
      ]

      {:ok, board, conflicts} = Merge.merge(results, "test_board")

      assert board.id == "test_board"
      assert board.soc == "i.MX6UL"
      assert board.ram_start == 2_147_483_648
      assert board.uart == "UART2"
      assert conflicts == []
    end

    test "scalar field conflict: two different values" do
      results = [
        {:ok, %{"ram_size" => %{value: "512MB", evidence: "512MB"}}},
        {:ok, %{"ram_size" => %{value: "1GB", evidence: "1GB"}}}
      ]

      {:ok, board, conflicts} = Merge.merge(results, "test_board")

      assert board.ram_size == :unknown

      ram_size_conflict = Enum.find(conflicts, fn c -> c.field == :ram_size end)
      assert ram_size_conflict != nil
      assert Enum.member?(ram_size_conflict.values, "512MB")
      assert Enum.member?(ram_size_conflict.values, "1GB")
    end

    test "scalar field no conflict: same value from multiple chunks" do
      results = [
        {:ok, %{"soc" => %{value: "i.MX6UL", evidence: "i.MX6UL"}}},
        {:ok, %{"soc" => %{value: "i.MX6UL", evidence: "i.MX6UL"}}}
      ]

      {:ok, board, conflicts} = Merge.merge(results, "test_board")

      assert board.soc == "i.MX6UL"
      # No conflict since values are the same
      soc_conflicts = Enum.filter(conflicts, fn c -> c.field == :soc end)
      assert soc_conflicts == []
    end

    test "missing fields stay :unknown" do
      results = [
        {:ok, %{"soc" => %{value: "i.MX6UL", evidence: "i.MX6UL"}}}
      ]

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      assert board.soc == "i.MX6UL"
      assert board.goarch == :unknown
      assert board.goarm == :unknown
      assert board.ram_start == :unknown
      assert board.ram_size == :unknown
      assert board.uart == :unknown
      assert board.tamago_soc == :unknown
      assert board.tamago_board == :unknown
      assert board.schematic == :unknown
      assert board.tree == :unknown
      assert board.notes == :unknown
    end

    test "peripherals merge: union" do
      results = [
        {:ok, %{"peripherals" => %{value: ["gpio", "usb"], evidence: ""}}},
        {:ok, %{"peripherals" => %{value: ["uart", "gpio"], evidence: ""}}}
      ]

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      assert Enum.sort(board.peripherals) == ["gpio", "uart", "usb"]
    end

    test "pinmux merge: union by signal" do
      results = [
        {:ok,
         %{
           "pinmux" => %{
             value: [
               %{"signal" => "UART2_TX", "pad" => "123", "fn" => "alt5"},
               %{"signal" => "UART2_RX", "pad" => "124", "fn" => "alt5"}
             ],
             evidence: ""
           }
         }},
        {:ok,
         %{
           "pinmux" => %{
             value: [
               %{"signal" => "GPIO1", "pad" => "200", "fn" => "gpio"}
             ],
             evidence: ""
           }
         }}
      ]

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      assert length(board.pinmux) == 3

      # Check specific signals
      uart2_tx = Enum.find(board.pinmux, fn row -> row.signal == "UART2_TX" end)
      assert uart2_tx != nil
      assert uart2_tx.pad == "123"

      gpio1 = Enum.find(board.pinmux, fn row -> row.signal == "GPIO1" end)
      assert gpio1 != nil
    end

    test "pinmux conflict: same signal with different pad or fn" do
      results = [
        {:ok,
         %{
           "pinmux" => %{
             value: [
               %{"signal" => "UART2_TX", "pad" => "123", "fn" => "alt5"}
             ],
             evidence: ""
           }
         }},
        {:ok,
         %{
           "pinmux" => %{
             value: [
               %{"signal" => "UART2_TX", "pad" => "456", "fn" => "alt5"}
             ],
             evidence: ""
           }
         }}
      ]

      {:ok, board, conflicts} = Merge.merge(results, "test_board")

      # Conflicting row should not be in pinmux
      uart2_rows = Enum.filter(board.pinmux, fn row -> row.signal == "UART2_TX" end)
      assert length(uart2_rows) == 0

      # Conflict should be reported
      pinmux_conflict = Enum.find(conflicts, fn c -> c.field == :pinmux end)
      assert pinmux_conflict != nil
    end

    test "hex value parsing for ram_start" do
      results = [
        {:ok, %{"ram_start" => %{value: "0x80000000", evidence: "0x80000000"}}}
      ]

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      assert board.ram_start == 2_147_483_648
    end

    test "integer value parsing for ram_start" do
      results = [
        {:ok, %{"ram_start" => %{value: 2_147_483_648, evidence: "2147483648"}}}
      ]

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      assert board.ram_start == 2_147_483_648
    end

    test "soc_key computed from soc" do
      results = [
        {:ok, %{"soc" => %{value: "i.MX6UL", evidence: "i.MX6UL"}}}
      ]

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      assert board.soc == "i.MX6UL"
      assert board.soc_key == "imx6ul"
    end

    test "empty results produce all unknown board" do
      results = []

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      assert board.id == "test_board"
      assert board.soc == :unknown
      assert board.goarch == :unknown
      assert board.ram_start == :unknown
      assert board.uart == :unknown
      assert board.peripherals == []
      assert board.pinmux == []
    end

    test "timeout results are ignored but logged" do
      results = [
        {:ok, %{"soc" => %{value: "i.MX6UL", evidence: "i.MX6UL"}}},
        {:timeout, "chunk timeout"},
        {:ok, %{"uart" => %{value: "UART2", evidence: "UART2"}}}
      ]

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      # Should use results from completed chunks
      assert board.soc == "i.MX6UL"
      assert board.uart == "UART2"
    end

    test "error results are ignored" do
      results = [
        {:ok, %{"soc" => %{value: "i.MX6UL", evidence: "i.MX6UL"}}},
        {:error, "parse error"},
        {:ok, %{"uart" => %{value: "UART2", evidence: "UART2"}}}
      ]

      {:ok, board, _conflicts} = Merge.merge(results, "test_board")

      # Should use results from completed chunks
      assert board.soc == "i.MX6UL"
      assert board.uart == "UART2"
    end
  end
end
