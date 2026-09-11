defmodule Hatch.KB.Loader do
  @moduledoc """
  Load boards from kb/boards/*/board.toml. Enforces I6 (unknown as a value).
  """

  alias Hatch.KB.Board

  @type warning :: %{board_id: String.t(), field: atom(), message: String.t()}
  @type err :: %{code: atom(), message: String.t()}

  @spec load_all(Path.t()) :: {:ok, [Board.t()], [warning()]} | {:error, err()}
  def load_all(kb_root) do
    # Configure sandbox for KB operations
    :ok = Application.put_env(:hatch, :kb_root, kb_root)

    case File.ls(Path.join(kb_root, "boards")) do
      {:ok, entries} ->
        boards_and_warnings =
          entries
          |> Enum.filter(&(not String.starts_with?(&1, "_")))
          |> Enum.map(&load_board_dir(kb_root, &1))

        boards = Enum.map(boards_and_warnings, &elem(&1, 0)) |> Enum.filter(& &1)
        all_warnings = Enum.flat_map(boards_and_warnings, &elem(&1, 1))

        if Enum.empty?(boards) and not Enum.empty?(boards_and_warnings) do
          {:error, %{code: :invalid_args, message: "No valid boards found"}}
        else
          {:ok, boards, all_warnings}
        end

      {:error, _} ->
        {:error, %{code: :not_found, message: "boards directory not found"}}
    end
  end

  @spec load(Path.t()) :: {:ok, Board.t(), [warning()]} | {:error, err()}
  def load(board_toml_path) do
    kb_root = Path.dirname(Path.dirname(board_toml_path))

    with {:ok, content} <- File.read(board_toml_path) do
      parse_board(content, board_toml_path, kb_root)
    else
      {:error, _} -> {:error, %{code: :not_found, message: "File not found"}}
    end
  end

  # --- Internal helpers ---

  defp load_board_dir(kb_root, board_dir) do
    board_toml_path = Path.join([kb_root, "boards", board_dir, "board.toml"])

    case load(board_toml_path) do
      {:ok, board, warnings} ->
        {board, warnings}

      {:error, err} ->
        # Parse error is a warning, not a crash
        warning = %{
          board_id: board_dir,
          field: :toml,
          message: "Failed to parse: #{err.message}"
        }

        {nil, [warning]}
    end
  end

  defp parse_board(content, board_toml_path, kb_root) do
    with {:ok, decoded} <- Toml.decode(content) do
      board_dir = Path.basename(Path.dirname(board_toml_path))
      source_path = Path.relative_to(board_toml_path, kb_root)

      {board, warnings} =
        build_board(decoded, board_dir, source_path, board_toml_path, kb_root)

      {:ok, board, warnings}
    else
      {:error, reason} ->
        {:error, %{code: :invalid_args, message: "TOML parse error: #{inspect(reason)}"}}
    end
  end

  defp build_board(decoded, board_dir, source_path, _board_toml_path, kb_root) do
    warnings = []

    # id: from file key or directory name
    {id, warnings} = parse_id(decoded, board_dir, warnings)

    # soc and soc_key
    {soc, soc_key, soc_warnings} = parse_soc(decoded)
    warnings = warnings ++ soc_warnings

    # goarch
    {goarch, goarch_warnings} = parse_goarch(decoded)
    warnings = warnings ++ goarch_warnings

    # goarm
    {goarm, goarm_warnings} = parse_goarm(decoded)
    warnings = warnings ++ goarm_warnings

    # ram_start and ram_size
    {ram_start, ram_warnings} = parse_ram_start(decoded)
    warnings = warnings ++ ram_warnings

    {ram_size, ram_size_warnings} = parse_ram_size(decoded)
    warnings = warnings ++ ram_size_warnings

    # uart
    {uart, uart_warnings} = parse_uart(decoded)
    warnings = warnings ++ uart_warnings

    # peripherals
    {peripherals, periph_warnings} = parse_peripherals(decoded)
    warnings = warnings ++ periph_warnings

    # pinmux
    {pinmux, pinmux_warnings} = parse_pinmux(decoded)
    warnings = warnings ++ pinmux_warnings

    # tamago_soc and tamago_board
    {tamago_soc, tamago_soc_warnings} = parse_string_field(decoded, "tamago_soc")
    warnings = warnings ++ tamago_soc_warnings

    {tamago_board, tamago_board_warnings} = parse_string_field(decoded, "tamago_board")
    warnings = warnings ++ tamago_board_warnings

    # schematic and tree
    {schematic, schematic_warnings} =
      parse_path_field(decoded, "schematic", kb_root)

    warnings = warnings ++ schematic_warnings

    {tree, tree_warnings} = parse_path_field(decoded, "tree", kb_root)
    warnings = warnings ++ tree_warnings

    # notes
    {notes, notes_warnings} = parse_string_field(decoded, "notes")
    warnings = warnings ++ notes_warnings

    # unknown keys
    unknown_warnings = find_unknown_keys(decoded)
    warnings = warnings ++ unknown_warnings

    board = %Board{
      id: id,
      source_path: source_path,
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

    {board,
     warnings
     |> Enum.map(&Map.put(&1, :board_id, id))
     |> Enum.map(&Map.put_new(&1, :field, :unknown))}
  end

  defp parse_id(decoded, board_dir, warnings) do
    case Map.get(decoded, "id") do
      nil ->
        {board_dir, warnings}

      id_value when is_binary(id_value) ->
        if id_value == board_dir do
          {id_value, warnings}
        else
          warning = %{
            field: :id,
            message: "Mismatch: file says #{id_value}, dir says #{board_dir}"
          }

          {board_dir, [warning | warnings]}
        end

      _ ->
        warning = %{field: :id, message: "Invalid id value"}
        {board_dir, [warning | warnings]}
    end
  end

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
    |> String.replace(~r/[-_ ]/, "")
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
      String.starts_with?(value, "0x") ->
        hex_part = String.slice(value, 2..-1//1)

        case Integer.parse(hex_part, 16) do
          {num, ""} -> {num, []}
          _ -> {:unknown, [%{field: String.to_atom(field_name), message: "Invalid hex"}]}
        end

      String.starts_with?(value, "0X") ->
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

      value when is_binary(value) ->
        {[], [%{field: :pinmux, message: "Pinmux table files not supported in v1"}]}

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

  defp parse_path_field(decoded, field_name, kb_root) do
    case Map.get(decoded, field_name) do
      nil ->
        {:unknown, []}

      value when is_binary(value) ->
        # Check if path stays within kb_root (basic check, not full symlink resolution)
        full_path = Path.expand(value, kb_root)
        kb_abs = Path.expand(kb_root)

        if String.starts_with?(full_path, kb_abs <> "/") or full_path == kb_abs do
          {value, []}
        else
          {:unknown, [%{field: String.to_atom(field_name), message: "Path outside KB"}]}
        end

      _ ->
        {:unknown, [%{field: String.to_atom(field_name), message: "Invalid path value"}]}
    end
  end

  defp find_unknown_keys(decoded) do
    known_keys = [
      "id",
      "soc",
      "goarch",
      "goarm",
      "ram_start",
      "ram_size",
      "uart",
      "peripherals",
      "pinmux",
      "tamago_soc",
      "tamago_board",
      "schematic",
      "tree",
      "notes"
    ]

    decoded
    |> Map.keys()
    |> Enum.filter(&(&1 not in known_keys))
    |> Enum.map(fn key ->
      %{field: :unknown, message: "Unknown key: #{key}"}
    end)
  end
end
