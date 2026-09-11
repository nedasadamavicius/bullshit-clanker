defmodule Hatch.KB.Delta do
  @moduledoc """
  Draft vs board field deltas.
  """

  alias Hatch.KB.Board

  @type t :: %__MODULE__{
          field: atom(),
          draft: term(),
          board: term(),
          kind: :same | :differs | :unknown_in_draft | :unknown_in_kb
        }

  defstruct [:field, :draft, :board, :kind]

  @fields [
    :soc,
    :goarch,
    :goarm,
    :ram_start,
    :ram_size,
    :uart,
    :peripherals,
    :pinmux,
    :tamago_soc,
    :tamago_board
  ]

  @spec compare(Board.t(), Board.t()) :: [t()]
  def compare(draft, board) do
    @fields
    |> Enum.map(&compare_field(&1, draft, board))
  end

  @spec render([t()]) :: String.t()
  def render(deltas) do
    rows =
      deltas
      |> Enum.map(fn delta ->
        field_str = Atom.to_string(delta.field)
        draft_str = format_value(delta.draft)
        board_str = format_value(delta.board)

        case delta.kind do
          :same ->
            "#{field_str}: #{draft_str}"

          :differs ->
            "#{field_str}: #{draft_str} → #{board_str}"

          :unknown_in_draft ->
            "#{field_str}: unknown (draft) vs #{board_str}"

          :unknown_in_kb ->
            "#{field_str}: #{draft_str} vs unknown (kb)"
        end
      end)

    Enum.join(rows, "\n")
  end

  # --- Private ---

  defp compare_field(field, draft, board) do
    draft_val = Map.fetch!(draft, field)
    board_val = Map.fetch!(board, field)

    kind = classify_field(draft_val, board_val)

    %__MODULE__{
      field: field,
      draft: draft_val,
      board: board_val,
      kind: kind
    }
  end

  defp classify_field(:unknown, :unknown), do: :same
  defp classify_field(:unknown, _board_val), do: :unknown_in_draft
  defp classify_field(_draft_val, :unknown), do: :unknown_in_kb

  defp classify_field([], []), do: :same

  defp classify_field(draft_val, board_val) when is_list(draft_val) and is_list(board_val) do
    if MapSet.equal?(MapSet.new(draft_val), MapSet.new(board_val)) do
      :same
    else
      :differs
    end
  end

  defp classify_field(draft_val, board_val) do
    if draft_val == board_val, do: :same, else: :differs
  end

  defp format_value(:unknown), do: "unknown"
  defp format_value([]), do: "unknown"
  defp format_value(num) when is_integer(num), do: "0x#{Integer.to_string(num, 16)}"
  defp format_value(str) when is_binary(str), do: str

  defp format_value(list) when is_list(list) do
    "[" <> Enum.join(list, ", ") <> "]"
  end
end
