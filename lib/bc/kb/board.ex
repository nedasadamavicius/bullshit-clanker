defmodule BC.KB.Board do
  @moduledoc """
  Board record: struct + helpers for :unknown semantics (I6).
  """

  @type t :: %__MODULE__{
          id: String.t(),
          source_path: Path.t(),
          soc: String.t() | :unknown,
          soc_key: String.t() | :unknown,
          goarch: String.t() | :unknown,
          goarm: String.t() | :unknown,
          ram_start: non_neg_integer() | :unknown,
          ram_size: non_neg_integer() | :unknown,
          uart: String.t() | :unknown,
          peripherals: [String.t()],
          pinmux: [%{signal: String.t(), pad: String.t(), fn: String.t()}],
          tamago_soc: String.t() | :unknown,
          tamago_board: String.t() | :unknown,
          schematic: Path.t() | :unknown,
          tree: Path.t() | :unknown,
          notes: String.t() | :unknown,
          raw: map()
        }

  @derive Jason.Encoder
  defstruct [
    :id,
    :source_path,
    :soc,
    :soc_key,
    :goarch,
    :goarm,
    :ram_start,
    :ram_size,
    :uart,
    :tamago_soc,
    :tamago_board,
    :schematic,
    :tree,
    :notes,
    peripherals: [],
    pinmux: [],
    raw: %{}
  ]

  @spec known?(term()) :: boolean()
  def known?(:unknown), do: false
  def known?([]), do: false
  def known?(_), do: true

  @spec fetch(t(), atom()) :: {:ok, term()} | :unknown
  def fetch(board, field) do
    value = Map.fetch!(board, field)
    if known?(value), do: {:ok, value}, else: :unknown
  end

  @spec to_facts(t()) :: String.t()
  def to_facts(board) do
    [
      "id: #{board.id}",
      "source_path: #{board.source_path}",
      "soc: #{format_value(board.soc)}",
      "goarch: #{format_value(board.goarch)}",
      "goarm: #{format_value(board.goarm)}",
      "ram_start: #{format_value(board.ram_start)}",
      "ram_size: #{format_value(board.ram_size)}",
      "uart: #{format_value(board.uart)}",
      "peripherals: #{format_value(board.peripherals)}",
      "pinmux: #{format_pinmux(board.pinmux)}",
      "tamago_soc: #{format_value(board.tamago_soc)}",
      "tamago_board: #{format_value(board.tamago_board)}",
      "schematic: #{format_value(board.schematic)}",
      "tree: #{format_value(board.tree)}",
      "notes: #{format_value(board.notes)}"
    ]
    |> Enum.join("\n")
  end

  defp format_value(:unknown), do: "unknown"
  defp format_value([]), do: "unknown"
  defp format_value(num) when is_integer(num), do: "0x#{Integer.to_string(num, 16)}"
  defp format_value(str) when is_binary(str), do: str
  defp format_value(list) when is_list(list), do: inspect(list)

  defp format_pinmux([]), do: "unknown"

  defp format_pinmux(rows) when is_list(rows) do
    rows
    |> Enum.map(fn row ->
      "{signal: #{row.signal}, pad: #{row.pad}, fn: #{row.fn}}"
    end)
    |> Enum.join("; ")
  end
end
