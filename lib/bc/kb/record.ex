defmodule BC.KB.Record do
  @moduledoc """
  Write a %Board{} (and optional nets) as kb/boards/<id>/ files.
  """

  alias BC.KB.Board

  @spec write(Path.t(), Board.t(), keyword()) ::
          :ok | {:error, %{code: atom(), message: String.t()}}
  def write(kb_root, %Board{} = board, opts \\ []) do
    id = board.id
    dest = Path.join([kb_root, "boards", id])

    with :ok <- File.mkdir_p(dest),
         :ok <- maybe_copy_pdf(Keyword.get(opts, :pdf), Path.join(dest, "schematic.pdf")),
         :ok <- File.write(Path.join(dest, "board.toml"), to_toml(board)),
         :ok <- maybe_write_nets(dest, Keyword.get(opts, :nets, [])) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, %{code: :upstream, message: "failed to write #{id}: #{inspect(reason)}"}}

      {:error, %{code: _} = err} ->
        {:error, err}
    end
  end

  @spec to_toml(Board.t()) :: String.t()
  def to_toml(%Board{} = board) do
    scalars =
      [
        encode_string("id", board.id),
        encode_known("soc", board.soc),
        encode_known("goarch", board.goarch),
        encode_known("goarm", board.goarm),
        encode_hex("ram_start", board.ram_start),
        encode_hex("ram_size", board.ram_size),
        encode_known("uart", board.uart),
        encode_list("peripherals", board.peripherals),
        encode_known("tamago_soc", board.tamago_soc),
        encode_known("tamago_board", board.tamago_board),
        encode_known("schematic", board.schematic),
        encode_known("tree", board.tree),
        encode_known("notes", board.notes)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    pinmux =
      board.pinmux
      |> Enum.map(&encode_pinmux/1)
      |> Enum.join("\n")

    body =
      if pinmux == "" do
        scalars <> "\n"
      else
        scalars <> "\n\n" <> pinmux <> "\n"
      end

    body
  end

  defp maybe_copy_pdf(nil, _dest), do: :ok

  defp maybe_copy_pdf(src, dest) do
    case File.cp(src, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_write_nets(_dest, []), do: :ok
  defp maybe_write_nets(_dest, nil), do: :ok

  defp maybe_write_nets(dest, nets) when is_list(nets) do
    payload = %{
      "nets" =>
        Enum.map(nets, fn net ->
          %{
            "name" => net.name,
            "pins" => Enum.map(net.pins || [], fn p -> %{"ref" => p.ref, "pin" => p.pin} end),
            "value" => value_json(net.value)
          }
        end)
    }

    File.write(Path.join(dest, "nets.json"), Jason.encode!(payload, pretty: true))
  end

  defp value_json(:unknown), do: "unknown"
  defp value_json(v), do: v

  defp encode_string(key, value) when is_binary(value) do
    "#{key} = #{toml_string(value)}"
  end

  defp encode_known(_key, :unknown), do: nil
  defp encode_known(_key, nil), do: nil
  defp encode_known(_key, ""), do: nil
  defp encode_known(key, value) when is_binary(value), do: encode_string(key, value)

  defp encode_hex(_key, :unknown), do: nil

  defp encode_hex(key, value) when is_integer(value) and value >= 0 do
    hex = Integer.to_string(value, 16)
    "#{key} = \"0x#{hex}\""
  end

  defp encode_list(_key, []), do: nil
  defp encode_list(_key, :unknown), do: nil

  defp encode_list(key, list) when is_list(list) do
    inner = Enum.map_join(list, ", ", &toml_string/1)
    "#{key} = [#{inner}]"
  end

  defp encode_pinmux(%{signal: signal, pad: pad, fn: fn_val}) do
    """
    [[pinmux]]
    signal = #{toml_string(signal)}
    pad = #{toml_string(pad)}
    fn = #{toml_string(fn_val)}
    """
    |> String.trim()
  end

  defp toml_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"#{escaped}\""
  end
end
