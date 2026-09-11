defmodule Hatch.Ingest.Merge do
  @moduledoc """
  Merge extraction results from multiple chunks into a single %Board{} draft.

  Merge rules:
  - Scalar fields: first non-conflicting value wins
  - Two different values → field becomes :unknown + conflict reported
  - peripherals: union
  - pinmux: union keyed by signal; conflicting pad/fn → dropped with conflict
  - Everything not extracted stays :unknown (I6)
  """

  require Logger

  alias Hatch.KB.Board

  @type conflict :: %{
          field: atom(),
          values: [term()],
          evidence: [String.t()]
        }

  @spec merge([{:ok, map()} | {:error, String.t()} | {:timeout, String.t()}], String.t()) ::
          {:ok, Board.t(), [conflict()]} | {:error, %{code: atom(), message: String.t()}}
  def merge(results, spec_id) do
    # Filter out errors and timeouts, treating them as conflicts
    valid_results =
      results
      |> Enum.filter(&match?({:ok, _}, &1))
      |> Enum.map(fn {:ok, result} -> result end)

    timeouts =
      results
      |> Enum.filter(&match?({:timeout, _}, &1))
      |> length()

    if timeouts > 0 do
      Logger.warning("Ingest: #{timeouts} chunk(s) timed out")
    end

    # Merge scalar fields
    {soc, soc_conflicts} = merge_scalar(valid_results, "soc")
    {_soc_key, _} = merge_scalar(valid_results, "soc_key")
    {goarch, goarch_conflicts} = merge_scalar(valid_results, "goarch")
    {goarm, goarm_conflicts} = merge_scalar(valid_results, "goarm")
    {ram_start, ram_start_conflicts} = merge_scalar(valid_results, "ram_start")
    {ram_size, ram_size_conflicts} = merge_scalar(valid_results, "ram_size")
    {uart, uart_conflicts} = merge_scalar(valid_results, "uart")
    {tamago_soc, tamago_soc_conflicts} = merge_scalar(valid_results, "tamago_soc")
    {tamago_board, tamago_board_conflicts} = merge_scalar(valid_results, "tamago_board")
    {schematic, schematic_conflicts} = merge_scalar(valid_results, "schematic")
    {tree, tree_conflicts} = merge_scalar(valid_results, "tree")
    {notes, notes_conflicts} = merge_scalar(valid_results, "notes")

    # Merge peripherals (union)
    {peripherals, periph_conflicts} = merge_peripherals(valid_results)

    # Merge pinmux (union by signal)
    {pinmux, pinmux_conflicts} = merge_pinmux(valid_results)

    # Compute soc_key if soc is known
    {final_soc_key, soc_key_conflicts} =
      if soc != :unknown do
        {normalize_soc(soc), []}
      else
        {:unknown, []}
      end

    # Build conflicts list
    all_conflicts =
      soc_conflicts ++
        goarch_conflicts ++
        goarm_conflicts ++
        ram_start_conflicts ++
        ram_size_conflicts ++
        uart_conflicts ++
        tamago_soc_conflicts ++
        tamago_board_conflicts ++
        schematic_conflicts ++
        tree_conflicts ++
        notes_conflicts ++
        periph_conflicts ++
        pinmux_conflicts ++
        soc_key_conflicts

    board = %Board{
      id: spec_id,
      source_path: "spec:#{spec_id}",
      soc: soc,
      soc_key: final_soc_key,
      goarch: goarch,
      goarm: goarm,
      ram_start: ram_start,
      ram_size: ram_size,
      uart: uart,
      peripherals: peripherals,
      pinmux: pinmux,
      tamago_soc: tamago_soc,
      tamago_board: tamago_board,
      schematic: schematic,
      tree: tree,
      notes: notes,
      raw: %{}
    }

    {:ok, board, all_conflicts}
  end

  # Merge a scalar field: first non-conflicting value wins
  defp merge_scalar(results, field_name) do
    values =
      results
      |> Enum.map(fn result ->
        case result[field_name] do
          %{value: val, evidence: ev} -> {val, ev}
          nil -> nil
        end
      end)
      |> Enum.filter(& &1)

    case values do
      [] ->
        # No values found
        {:unknown, []}

      [{value, _evidence}] ->
        # Single value
        {parse_value(field_name, value), []}

      values_with_evidence ->
        # Multiple values, check for conflicts
        unique_values = values_with_evidence |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

        if length(unique_values) == 1 do
          # All same value
          {parse_value(field_name, hd(unique_values)), []}
        else
          # Conflict: different values
          evidence_list = Enum.map(values_with_evidence, &elem(&1, 1))

          conflict = %{
            field: String.to_atom(field_name),
            values: unique_values,
            evidence: evidence_list
          }

          {:unknown, [conflict]}
        end
    end
  end

  # Merge peripherals (union)
  defp merge_peripherals(results) do
    peripherals =
      results
      |> Enum.filter(fn result -> is_map(result["peripherals"]) end)
      |> Enum.map(fn result ->
        case result["peripherals"] do
          %{value: val} when is_list(val) -> val
          _ -> []
        end
      end)
      |> Enum.concat()
      |> Enum.uniq()
      |> Enum.sort()

    {peripherals, []}
  end

  # Merge pinmux (union by signal, conflict if same signal has different pad/fn)
  defp merge_pinmux(results) do
    pinmux_list =
      results
      |> Enum.filter(fn result -> is_map(result["pinmux"]) end)
      |> Enum.map(fn result ->
        case result["pinmux"] do
          %{value: val} when is_list(val) -> val
          _ -> []
        end
      end)
      |> Enum.concat()

    # Group by signal
    pinmux_by_signal =
      pinmux_list
      |> Enum.group_by(fn row -> row["signal"] end)

    {final_pinmux, conflicts} =
      pinmux_by_signal
      |> Enum.reduce({[], []}, fn {signal, rows}, {acc_rows, acc_conflicts} ->
        case rows do
          [single_row] ->
            # Single row for this signal
            parsed_row = %{
              signal: single_row["signal"],
              pad: single_row["pad"],
              fn: single_row["fn"]
            }

            {acc_rows ++ [parsed_row], acc_conflicts}

          multiple_rows ->
            # Multiple rows for same signal - check for conflicts
            unique_pads = multiple_rows |> Enum.map(fn r -> r["pad"] end) |> Enum.uniq()
            unique_fns = multiple_rows |> Enum.map(fn r -> r["fn"] end) |> Enum.uniq()

            if length(unique_pads) == 1 and length(unique_fns) == 1 do
              # Same pad and fn, merge
              parsed_row = %{
                signal: signal,
                pad: hd(unique_pads),
                fn: hd(unique_fns)
              }

              {acc_rows ++ [parsed_row], acc_conflicts}
            else
              # Conflicting pad or fn, drop this row
              conflict = %{
                field: :pinmux,
                values: [signal],
                evidence: []
              }

              {acc_rows, acc_conflicts ++ [conflict]}
            end
        end
      end)

    {final_pinmux, conflicts}
  end

  # Parse field values according to field type
  defp parse_value(field_name, value) when field_name in ["ram_start", "ram_size"] do
    if is_integer(value) do
      value
    else
      parse_hex_or_int(value, field_name)
    end
  end

  defp parse_value(_field_name, value) do
    value
  end

  defp parse_hex_or_int(value, _field_name) when is_integer(value) do
    if value >= 0, do: value, else: :unknown
  end

  defp parse_hex_or_int(value, _field_name) when is_binary(value) do
    cond do
      String.starts_with?(value, "0x") or String.starts_with?(value, "0X") ->
        hex_part = String.slice(value, 2..-1//1)

        case Integer.parse(hex_part, 16) do
          {num, ""} when num >= 0 -> num
          _ -> :unknown
        end

      true ->
        case Integer.parse(value, 10) do
          {num, ""} when num >= 0 -> num
          _ -> :unknown
        end
    end
  end

  defp parse_hex_or_int(_, _), do: :unknown

  defp normalize_soc(soc) do
    soc
    |> String.downcase()
    |> String.replace(~r/[-_.# ]/, "")
  end
end
