defmodule Mix.Tasks.Bc.Kb.Ingest do
  @moduledoc """
  Ingest schematic PDFs into the knowledge base.

  Each PDF becomes `kb/boards/<id>/board.toml` plus a copied `schematic.pdf`.
  Named nets, when the document actually states them, are written to `nets.json`.
  Unknown fields stay unknown. The session still never reads a PDF.

  ## Usage

      mix bc.kb.ingest ./datasheets/usbarmory.pdf
      mix bc.kb.ingest --pdf ./datasheets/
      mix bc.kb.ingest a.pdf b.pdf --force

  `--kb` defaults to `./kb`. Board id is the PDF filename, slugified
  (`USB Armory.PDF` → `usb_armory`).

  ## API key

  Default provider is Claude. Put `ANTHROPIC_API_KEY` (or `BC_API_KEY`) in
  `config/secrets.env` — copy `config/secrets.env.example`. Env vars still work.

  Used: `BC_PROVIDER` (`claude` | `xai` | `openai`), `BC_MODEL` / `BC_MODEL_INGEST`, `BC_API_BASE`

  Needs `pdftotext` (poppler-utils) on PATH.
  """

  use Mix.Task

  alias BC.Ingest.Pdf

  @shortdoc "Ingest PDFs into kb/boards/<id>/board.toml"

  @switches [
    kb: :string,
    pdf: :keep,
    force: :boolean,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: @switches, aliases: [h: :help, f: :force])

    if opts[:help] do
      Mix.shell().info(@moduledoc)
      halt(0)
    else
      run_ingest(opts, rest)
    end
  end

  defp run_ingest(opts, rest) do
    unless BC.Provider.has_api_key?() do
      Mix.shell().error(
        "bc.kb.ingest: no API key. Copy config/secrets.env.example to config/secrets.env and paste ANTHROPIC_API_KEY (or set BC_API_KEY)."
      )

      halt(1)
    end

    kb = opts[:kb] || "kb"
    pdfs = Keyword.get_values(opts, :pdf) ++ rest

    cond do
      pdfs == [] ->
        Mix.shell().error("bc.kb.ingest: pass a PDF path (file or directory)")
        halt(1)

      true ->
        Mix.Task.run("app.start")
        put_env_defaults()
        do_run(Path.expand(kb), pdfs, Keyword.get(opts, :force, false))
    end
  end

  defp do_run(kb_root, pdfs, force?) do
    File.mkdir_p!(Path.join(kb_root, "boards"))
    put_ingest_config(kb_root)

    case Pdf.ingest_paths(pdfs, kb_root, force: force?) do
      {:ok, results} ->
        Enum.each(results, &print_result/1)
        Mix.shell().info("#{length(results)} board(s) written under #{kb_root}/boards")
        Mix.shell().info("Start chatting: mix bc --kb #{inspect(kb_root)}")
        halt(0)

      {:error, err} ->
        Enum.each(err[:results] || [], &print_result/1)
        Mix.shell().error("bc.kb.ingest: #{err.message}")
        halt(1)
    end
  end

  defp print_result(result) do
    soc = (BC.KB.Board.known?(result.board.soc) && result.board.soc) || "unknown"
    Mix.shell().info("#{result.id}  soc=#{soc}  → #{result.dest}")

    unknown =
      [:soc, :goarch, :ram_start, :ram_size, :uart, :tamago_soc, :tamago_board]
      |> Enum.reject(&BC.KB.Board.known?(Map.fetch!(result.board, &1)))

    if unknown != [], do: Mix.shell().info("  unknown: #{Enum.join(unknown, ", ")}")

    Enum.each(result.conflicts, fn conflict ->
      Mix.shell().info("  conflict: #{conflict.field} — #{inspect(conflict.values)}")
    end)
  end

  defp put_env_defaults do
    case BC.Provider.resolve(System.get_env()) do
      {:ok, resolved} ->
        unless System.get_env("BC_MODEL"), do: System.put_env("BC_MODEL", resolved.model)

        unless System.get_env("BC_API_BASE"),
          do: System.put_env("BC_API_BASE", resolved.api_base)

      _ ->
        :ok
    end
  end

  defp put_ingest_config(kb_root) do
    {:ok, resolved} = BC.Provider.resolve(System.get_env())

    config = %BC.Config{
      kb_root: kb_root,
      tree_root: nil,
      model: resolved.model,
      ingest_model: resolved.ingest_model,
      build_model: nil,
      api_base: resolved.api_base,
      api_key: resolved.api_key,
      tamago_go: System.get_env("BC_TAMAGO_GO") || "tamago-go",
      build_timeout_ms: 120_000,
      provider: resolved.provider
    }

    BC.Config.put(config)
    Application.put_env(:bc, :config, config)
    Application.put_env(:bc, :kb_root, kb_root)
  end

  defp halt(code) do
    halt_fn = Application.get_env(:bc, :halt, &System.halt/1)
    halt_fn.(code)
  end
end
