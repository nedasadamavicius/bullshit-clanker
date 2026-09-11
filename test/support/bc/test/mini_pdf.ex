defmodule BC.Test.MiniPdf do
  @moduledoc false

  @spec write!(Path.t(), [String.t()]) :: :ok
  def write!(path, lines) when is_list(lines) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, build(lines))
    :ok
  end

  @spec build([String.t()]) :: binary()
  def build(lines) do
    stream_body = content_stream(lines)

    objects = [
      "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
      "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
      "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
      "4 0 obj\n<< /Length #{byte_size(stream_body)} >>\nstream\n" <>
        stream_body <> "endstream\nendobj\n",
      "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n"
    ]

    header = "%PDF-1.4\n"

    {body, offsets} =
      Enum.reduce(objects, {header, []}, fn obj, {acc, offs} ->
        {acc <> obj, offs ++ [byte_size(acc)]}
      end)

    xref_offset = byte_size(body)

    xref =
      [
        "xref\n0 6\n",
        "0000000000 65535 f \n"
        | Enum.map(offsets, fn off ->
            String.pad_leading(Integer.to_string(off), 10, "0") <> " 00000 n \n"
          end)
      ]
      |> IO.iodata_to_binary()

    trailer = """
    trailer
    << /Size 6 /Root 1 0 R >>
    startxref
    #{xref_offset}
    %%EOF
    """

    body <> xref <> trailer
  end

  defp content_stream(lines) do
    moves =
      lines
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {line, idx} ->
        escaped = pdf_escape(line)

        if idx == 0 do
          "(#{escaped}) Tj"
        else
          "0 -16 Td (#{escaped}) Tj"
        end
      end)

    "BT\n/F1 12 Tf\n72 720 Td\n#{moves}\nET\n"
  end

  defp pdf_escape(text) do
    text
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("(", "\\(")
    |> String.replace(")", "\\)")
  end
end
