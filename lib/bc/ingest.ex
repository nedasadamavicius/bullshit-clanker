defmodule BC.Ingest do
  @moduledoc """
  Spec text → %Board{} draft extraction.

  Entry points:
  1. --spec PATH on CLI (markdown or board.toml)
  2. /spec command in TUI (future)

  Two paths chosen by content:
  - TOML with id/soc key → Loader semantics directly
  - Otherwise → Model extraction via chunks
  """

  require Logger

  alias BC.KB.Board
  alias BC.Ingest.{Worker, Merge}

  @type conflict :: %{
          field: atom(),
          values: [term()],
          evidence: [String.t()]
        }

  @spec ingest(String.t(), String.t()) ::
          {:ok, Board.t(), [conflict()]} | {:error, %{code: atom(), message: String.t()}}
  def ingest(spec_text, spec_id) do
    case try_toml_path(spec_text) do
      {:ok, board, conflicts} ->
        {:ok, board, conflicts}

      :not_toml ->
        extract_with_model(spec_text, spec_id)
    end
  end

  # If TOML parses and has id or soc key, use Loader semantics
  defp try_toml_path(spec_text) do
    case Toml.decode(spec_text) do
      {:ok, decoded} ->
        if Map.has_key?(decoded, "id") or Map.has_key?(decoded, "soc") do
          # Build a board from the TOML directly
          # Use the decoded map to build a Board
          {board, conflicts} = build_board_from_toml(decoded)
          {:ok, board, conflicts}
        else
          :not_toml
        end

      {:error, _} ->
        :not_toml
    end
  end

  # Build a board from decoded TOML for spec file
  defp build_board_from_toml(decoded) do
    # Extract id - use "spec" as default if not provided
    id = Map.get(decoded, "id", "spec")

    # Parse fields using Loader's parsers (reuse the same logic)
    {soc, soc_key, soc_warnings} = parse_soc(decoded)
    {goarch, goarch_warnings} = parse_goarch(decoded)
    {goarm, goarm_warnings} = parse_goarm(decoded)
    {ram_start, ram_warnings} = parse_ram_start(decoded)
    {ram_size, ram_size_warnings} = parse_ram_size(decoded)
    {uart, uart_warnings} = parse_uart(decoded)
    {peripherals, periph_warnings} = parse_peripherals(decoded)
    {pinmux, pinmux_warnings} = parse_pinmux(decoded)
    {tamago_soc, tamago_soc_warnings} = parse_string_field(decoded, "tamago_soc")
    {tamago_board, tamago_board_warnings} = parse_string_field(decoded, "tamago_board")
    {schematic, schematic_warnings} = parse_path_field(decoded, "schematic")
    {tree, tree_warnings} = parse_path_field(decoded, "tree")
    {notes, notes_warnings} = parse_string_field(decoded, "notes")

    warnings =
      soc_warnings ++
        goarch_warnings ++
        goarm_warnings ++
        ram_warnings ++
        ram_size_warnings ++
        uart_warnings ++
        periph_warnings ++
        pinmux_warnings ++
        tamago_soc_warnings ++
        tamago_board_warnings ++
        schematic_warnings ++
        tree_warnings ++
        notes_warnings

    board = %Board{
      id: id,
      source_path: "spec:#{id}",
      soc: soc,
      soc_key: soc_key,
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
      raw: decoded
    }

    # Convert warnings to conflicts if any
    conflicts =
      warnings
      |> Enum.map(&warning_to_conflict/1)
      |> Enum.filter(& &1)

    {board, conflicts}
  end

  defp warning_to_conflict(%{field: field, message: _msg}) when field != :unknown do
    nil
  end

  defp warning_to_conflict(_), do: nil

  # Extract via model when content is not TOML
  defp extract_with_model(spec_text, spec_id) do
    chunks = split_chunks(spec_text)
    Logger.debug("Ingest: split into #{length(chunks)} chunks for processing")

    # Process chunks with Task.async_stream
    results =
      chunks
      |> Task.async_stream(&Worker.process_chunk/1,
        max_concurrency: 4,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.map(&handle_chunk_result/1)

    # Merge results
    case Merge.merge(results, spec_id) do
      {:ok, board, conflicts} ->
        {:ok, board, conflicts}

      {:error, error} ->
        {:error, error}
    end
  end

  defp handle_chunk_result({:ok, result}) do
    result
  end

  defp handle_chunk_result({:exit, _reason}) do
    # Chunk timed out or failed
    {:timeout, "chunk processing timeout"}
  end

  # Split spec_text into chunks of ≤6000 chars on paragraph boundaries with 200-char overlap
  defp split_chunks(text) do
    # Split by paragraph (double newline)
    paragraphs = String.split(text, ~r/\n\n+/, trim: true)

    {chunks, current_chunk} =
      Enum.reduce(paragraphs, {[], ""}, fn paragraph, {acc_chunks, current_chunk} ->
        para_with_sep = paragraph <> "\n\n"

        if byte_size(current_chunk) + byte_size(para_with_sep) <= 6000 do
          # Add to current chunk
          new_chunk = current_chunk <> para_with_sep
          {acc_chunks, new_chunk}
        else
          # Start new chunk with overlap
          if byte_size(current_chunk) > 0 do
            # Extract last 200 chars as overlap
            overlap = extract_overlap(current_chunk, 200)
            new_chunk = overlap <> para_with_sep
            {acc_chunks ++ [String.trim_trailing(current_chunk)], new_chunk}
          else
            # Current chunk too large, just take what we have
            {acc_chunks ++ [String.trim_trailing(current_chunk)], para_with_sep}
          end
        end
      end)

    # Add final chunk
    if byte_size(current_chunk) > 0 do
      chunks ++ [String.trim_trailing(current_chunk)]
    else
      chunks
    end
  end

  defp extract_overlap(text, max_chars) do
    text_byte_size = byte_size(text)

    if text_byte_size <= max_chars do
      text
    else
      offset = text_byte_size - max_chars
      String.slice(text, offset..-1)
    end
  end

  # Parsing helpers (reused from Loader)
  defp parse_soc(decoded) do
    case Map.get(decoded, "soc") do
      nil -> {:unknown, :unknown, []}
      value when is_binary(value) -> {value, normalize_soc(value), []}
      _ -> {:unknown, :unknown, [%{field: :soc, message: "Invalid soc value"}]}
    end
  end

  defp normalize_soc(soc) do
    soc
    |> String.downcase()
    |> String.replace(~r/[-_.# ]/, "")
  end

  defp parse_goarch(decoded) do
    case Map.get(decoded, "goarch") do
      nil ->
        {:unknown, []}

      value when is_binary(value) ->
        if value in ["arm", "arm64", "riscv64"] do
          {value, []}
        else
          {:unknown, [%{field: :goarch, message: "Invalid goarch value"}]}
        end

      _ ->
        {:unknown, [%{field: :goarch, message: "Invalid goarch value"}]}
    end
  end

  defp parse_goarm(decoded) do
    case Map.get(decoded, "goarm") do
      nil ->
        {:unknown, []}

      value when is_binary(value) ->
        if value in ["5", "6", "7"] do
          {value, []}
        else
          {:unknown, [%{field: :goarm, message: "Invalid goarm value"}]}
        end

      _ ->
        {:unknown, [%{field: :goarm, message: "Invalid goarm value"}]}
    end
  end

  defp parse_ram_start(decoded) do
    case Map.get(decoded, "ram_start") do
      nil -> {:unknown, []}
      value -> parse_hex_or_int(value, "ram_start")
    end
  end

  defp parse_ram_size(decoded) do
    case Map.get(decoded, "ram_size") do
      nil -> {:unknown, []}
      value -> parse_hex_or_int(value, "ram_size")
    end
  end

  defp parse_hex_or_int(value, field_name) when is_integer(value) do
    if value >= 0 do
      {value, []}
    else
      {:unknown, [%{field: String.to_atom(field_name), message: "Negative value"}]}
    end
  end

  defp parse_hex_or_int(value, field_name) when is_binary(value) do
    cond do
      String.starts_with?(value, "0x") or String.starts_with?(value, "0X") ->
        hex_part = String.slice(value, 2..-1//1)

        case Integer.parse(hex_part, 16) do
          {num, ""} -> {num, []}
          _ -> {:unknown, [%{field: String.to_atom(field_name), message: "Invalid hex"}]}
        end

      true ->
        case Integer.parse(value, 10) do
          {num, ""} when num >= 0 -> {num, []}
          _ -> {:unknown, [%{field: String.to_atom(field_name), message: "Invalid number"}]}
        end
    end
  end

  defp parse_hex_or_int(_, field_name) do
    {:unknown, [%{field: String.to_atom(field_name), message: "Invalid type"}]}
  end

  defp parse_uart(decoded) do
    case Map.get(decoded, "uart") do
      nil -> {:unknown, []}
      value when is_binary(value) -> {String.trim(value), []}
      _ -> {:unknown, [%{field: :uart, message: "Invalid uart value"}]}
    end
  end

  defp parse_peripherals(decoded) do
    case Map.get(decoded, "peripherals") do
      nil ->
        {[], []}

      value when is_list(value) ->
        peripherals =
          value
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&String.downcase/1)
          |> Enum.uniq()
          |> Enum.sort()

        {peripherals, []}

      _ ->
        {[], [%{field: :peripherals, message: "Not a list"}]}
    end
  end

  defp parse_pinmux(decoded) do
    case Map.get(decoded, "pinmux") do
      nil ->
        {[], []}

      rows when is_list(rows) ->
        pinmux = []
        warnings = []

        {pinmux, warnings} =
          Enum.reduce(rows, {pinmux, warnings}, fn row, {acc_rows, acc_warnings} ->
            case parse_pinmux_row(row) do
              {:ok, parsed_row} -> {[parsed_row | acc_rows], acc_warnings}
              {:error, warning} -> {acc_rows, [warning | acc_warnings]}
            end
          end)

        {Enum.reverse(pinmux), warnings}

      _ ->
        {[], [%{field: :pinmux, message: "Invalid pinmux value"}]}
    end
  end

  defp parse_pinmux_row(row) when is_map(row) do
    signal = Map.get(row, "signal")
    pad = Map.get(row, "pad")
    fn_val = Map.get(row, "fn")

    if is_binary(signal) and is_binary(pad) and is_binary(fn_val) do
      {:ok, %{signal: signal, pad: pad, fn: fn_val}}
    else
      {:error, %{field: :pinmux, message: "Pinmux row missing required fields"}}
    end
  end

  defp parse_pinmux_row(_) do
    {:error, %{field: :pinmux, message: "Pinmux row not a table"}}
  end

  defp parse_string_field(decoded, field_name) do
    case Map.get(decoded, field_name) do
      nil -> {:unknown, []}
      value when is_binary(value) -> {String.trim(value), []}
      _ -> {:unknown, [%{field: String.to_atom(field_name), message: "Invalid value"}]}
    end
  end

  defp parse_path_field(decoded, field_name) do
    case Map.get(decoded, field_name) do
      nil ->
        {:unknown, []}

      value when is_binary(value) ->
        {value, []}

      _ ->
        {:unknown, [%{field: String.to_atom(field_name), message: "Invalid path value"}]}
    end
  end
end
