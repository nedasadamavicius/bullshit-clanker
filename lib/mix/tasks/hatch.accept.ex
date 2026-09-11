defmodule Mix.Tasks.Hatch.Accept do
  @moduledoc """
  Live V1 acceptance run (not used in CI).

  This task is the human: the one place outside the TUI allowed to mint a
  write permit (spec 009, 013). Excluded from the 009 grep test by filename
  (`lib/mix/tasks/hatch.accept.ex`).

  ## Usage

      mix hatch.accept --kb PATH --spec PATH --tree PATH [--runs N]

  ## Environment

  Required:

    * `HATCH_API_KEY` — model API key. Refuses to start if missing.

  Used:

    * `HATCH_MODEL` — session model (default: gpt-4o)
    * `HATCH_MODEL_INGEST` — ingest model (defaults to `HATCH_MODEL`)
    * `HATCH_API_BASE` — OpenAI-compatible base URL
    * `HATCH_TAMAGO_GO` — real `tamago-go` binary (default: tamago-go)
    * `HATCH_BUILD_TIMEOUT_MS` — build timeout (default: 120000)
  """

  use Mix.Task

  alias Hatch.Acceptance
  alias Hatch.Acceptance.{Fixture, Report}

  @shortdoc "Run live held-out V1 acceptance"

  @switches [
    kb: :string,
    spec: :string,
    tree: :string,
    runs: :integer,
    help: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches, aliases: [h: :help])

    if opts[:help] do
      Mix.shell().info(@moduledoc)
      halt(0)
    else
      run_accept(opts)
    end
  end

  defp run_accept(opts) do
    unless System.get_env("HATCH_API_KEY") do
      Mix.shell().error("hatch.accept: HATCH_API_KEY is required (refusing to half-run)")
      halt(1)
    end

    kb = opts[:kb] || Fixture.kb_path()
    spec = opts[:spec] || Fixture.spec_path()
    tree = opts[:tree] || Fixture.tree_path()
    runs = opts[:runs] || 1

    unless File.dir?(kb) do
      Mix.shell().error("hatch.accept: --kb is not a directory: #{kb}")
      halt(1)
    end

    unless File.exists?(spec) do
      Mix.shell().error("hatch.accept: --spec not found: #{spec}")
      halt(1)
    end

    unless File.dir?(tree) do
      Mix.shell().error("hatch.accept: --tree is not a directory: #{tree}")
      halt(1)
    end

    Mix.Task.run("app.start")
    put_live_env_defaults()

    results =
      Enum.map(1..runs, fn n ->
        Mix.shell().info("=== hatch.accept run #{n}/#{runs} ===")
        run_one(kb, spec, tree)
      end)

    passed = Enum.count(results, fn {_tag, payload} -> Report.passed?(payload.report) end)
    Mix.shell().info("pass rate: #{passed}/#{runs}")

    Enum.each(results, fn {_tag, payload} ->
      Report.append_history("acceptance-history.jsonl", payload.report)
    end)

    last = results |> List.last() |> elem(1)
    print_report(last)

    if Enum.all?(results, fn {_tag, payload} -> Report.passed?(payload.report) end) do
      halt(0)
    else
      halt(1)
    end
  end

  defp run_one(kb, spec, tree) do
    Acceptance.run(
      mode: :live,
      kb: kb,
      spec: spec,
      tree: tree,
      output_dir: File.cwd!()
    )
  end

  defp print_report(%{report: report, extras: extras}) do
    hit = extras.expected_hits |> List.first()
    why = if hit, do: Enum.join(hit.why, "; "), else: "(none)"

    Mix.shell().info("""

    nearest:   #{report.nearest_board}  (expected #{report.expected_board})
    why:       #{why}
    citations: #{inspect(citations(extras.proposal))}
    deltas:
    #{render_deltas(extras.proposal)}
    apply:     #{report.apply_ok}  #{extras.apply_output}
    build:     exit #{report.build_exit}
    #{extras.build_log}
    duration:  #{report.duration_ms} ms
    usage:     #{inspect(report.usage)}
    """)
  end

  defp citations(nil), do: []
  defp citations(proposal), do: proposal.citations

  defp render_deltas(nil), do: "  (none)"

  defp render_deltas(proposal) do
    Hatch.KB.Delta.render(proposal.deltas || [])
  end

  defp put_live_env_defaults do
    unless System.get_env("HATCH_MODEL"), do: System.put_env("HATCH_MODEL", "gpt-4o")

    unless System.get_env("HATCH_API_BASE"),
      do: System.put_env("HATCH_API_BASE", "https://api.openai.com/v1")
  end

  defp halt(code) do
    halt_fn = Application.get_env(:hatch, :halt, &System.halt/1)
    halt_fn.(code)
  end
end
