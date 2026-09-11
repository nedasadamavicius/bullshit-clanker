defmodule BC.Ingest.Pdf do
  @moduledoc """
  Offline schematic ingest: PDF → board.toml + optional nets.json.

  The session never reads a PDF. This is the one-shot path PRODUCT.md
  describes: extract text (pdftotext port), run 012 ingest, write records.
  """

  alias BC.Ingest
  alias BC.Ingest.Nets
  alias BC.KB.Record

  @timeout_ms 60_000

  @type result :: %{
          id: String.t(),
          dest: Path.t(),
          board: BC.KB.Board.t(),
          conflicts: [map()],
          nets: [map()]
        }

  @spec extract_text(Path.t()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def extract_text(pdf_path) do
    abs = Path.expand(pdf_path)

    cond do
      not File.exists?(abs) ->
        {:error, %{code: :not_found, message: "PDF not found: #{pdf_path}"}}

      not pdf?(abs) ->
        {:error, %{code: :invalid_args, message: "not a PDF: #{pdf_path}"}}

      true ->
        run_pdftotext(abs)
    end
  end

  @spec slug(Path.t()) :: String.t()
  def slug(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "board"
      id -> id
    end
  end

  @spec list_pdfs(Path.t()) :: [Path.t()]
  def list_pdfs(path) do
    abs = Path.expand(path)

    cond do
      File.regular?(abs) ->
        [abs]

      File.dir?(abs) ->
        abs
        |> Path.join("**/*.pdf")
        |> Path.wildcard(match_dot: false)
        |> Enum.filter(&File.regular?/1)
        |> Enum.sort()

      true ->
        []
    end
  end

  @spec ingest_file(Path.t(), Path.t(), keyword()) ::
          {:ok, result()} | {:error, %{code: atom(), message: String.t()}}
  def ingest_file(pdf_path, kb_root, opts \\ []) do
    id = Keyword.get(opts, :id) || slug(pdf_path)
    dest = Path.join([kb_root, "boards", id])
    toml = Path.join(dest, "board.toml")
    force? = Keyword.get(opts, :force, false)

    cond do
      File.exists?(toml) and not force? ->
        {:error,
         %{
           code: :exists,
           message: "board already exists: #{id} (pass --force to overwrite)"
         }}

      true ->
        do_ingest(pdf_path, kb_root, id, dest, opts)
    end
  end

  @spec ingest_paths([Path.t()], Path.t(), keyword()) ::
          {:ok, [result()]} | {:error, %{code: atom(), message: String.t(), results: [result()]}}
  def ingest_paths(paths, kb_root, opts \\ []) do
    pdfs =
      paths
      |> Enum.flat_map(&list_pdfs/1)
      |> Enum.uniq()

    if pdfs == [] do
      {:error, %{code: :not_found, message: "no PDF files found"}}
    else
      {ok, err, _used} =
        Enum.reduce(pdfs, {[], nil, MapSet.new()}, fn pdf, {acc, err, used} ->
          if err do
            {acc, err, used}
          else
            id = unique_id(slug(pdf), used)
            used = MapSet.put(used, id)

            case ingest_file(pdf, kb_root, Keyword.put(opts, :id, id)) do
              {:ok, result} -> {[result | acc], nil, used}
              {:error, e} -> {acc, Map.put(e, :pdf, pdf), used}
            end
          end
        end)

      results = Enum.reverse(ok)

      if err do
        {:error, Map.put(err, :results, results)}
      else
        {:ok, results}
      end
    end
  end

  defp do_ingest(pdf_path, kb_root, id, dest, opts) do
    extract_nets? = Keyword.get(opts, :extract_nets, true)

    with {:ok, text} <- extract_text(pdf_path),
         {:ok, board, conflicts} <- Ingest.ingest(text, id),
         {:ok, nets} <- maybe_nets(text, extract_nets?) do
      board = %{board | schematic: Path.join(["boards", id, "schematic.pdf"])}

      case Record.write(kb_root, board, pdf: pdf_path, nets: nets) do
        :ok ->
          {:ok,
           %{
             id: id,
             dest: dest,
             board: board,
             conflicts: conflicts,
             nets: nets
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  defp maybe_nets(_text, false), do: {:ok, []}
  defp maybe_nets(text, true), do: Nets.extract(text)

  defp unique_id(id, used) do
    if MapSet.member?(used, id) do
      unique_id(id <> "_2", used)
    else
      id
    end
  end

  defp pdf?(path) do
    String.ends_with?(String.downcase(path), ".pdf")
  end

  defp run_pdftotext(pdf_path) do
    case System.find_executable("pdftotext") do
      nil ->
        {:error,
         %{
           code: :no_toolchain,
           message: "pdftotext not found on PATH (install poppler-utils)"
         }}

      bin ->
        port =
          Port.open({:spawn_executable, bin}, [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            args: ["-layout", "-enc", "UTF-8", pdf_path, "-"]
          ])

        case collect_port(port, <<>>, @timeout_ms) do
          {:ok, 0, text} ->
            trimmed = String.trim(text)

            if trimmed == "" do
              {:error,
               %{
                 code: :empty,
                 message:
                   "no extractable text in #{Path.basename(pdf_path)} (scanned PDF? add a text layer; BC does not OCR live)"
               }}
            else
              {:ok, trimmed}
            end

          {:ok, status, out} ->
            {:error,
             %{
               code: :upstream,
               message: "pdftotext exited #{status}: #{String.slice(out, 0, 200)}"
             }}

          {:error, _} = err ->
            err
        end
    end
  end

  defp collect_port(port, acc, timeout) do
    receive do
      {^port, {:data, chunk}} ->
        collect_port(port, acc <> chunk, timeout)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc}
    after
      timeout ->
        Port.close(port)

        {:error, %{code: :timeout, message: "pdftotext timed out after #{timeout}ms"}}
    end
  end
end
