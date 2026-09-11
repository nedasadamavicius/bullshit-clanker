defmodule Mix.Tasks.BC.Accept do
  @moduledoc """
  Live V1 acceptance run (not used in CI).

  This task is the human: the one place outside the TUI allowed to mint a
  write permit (spec 009, 013). Excluded from the 009 grep test by filename
  (`lib/mix/tasks/bc.accept.ex`).

  ## Usage

      mix bc.accept --kb PATH --spec PATH --tree PATH [--runs N]

  ## API key

  Required:

    * `ANTHROPIC_API_KEY` or `BC_API_KEY` in `config/secrets.env`
      (copy `config/secrets.env.example`). Env vars still work. Refuses to start if missing.

  Used:

    * `BC_PROVIDER` — `claude` (default) | `xai` | `openai`
    * `BC_MODEL` — session model (default depends on provider)
    * `BC_MODEL_INGEST` — ingest model (defaults to `BC_MODEL`)
    * `BC_API_BASE` — OpenAI-compatible base URL (default depends on provider)
    * `BC_TAMAGO_GO` — real `tamago-go` binary (default: tamago-go)
    * `BC_BUILD_TIMEOUT_MS` — build timeout (default: 120000)
  """

  use Mix.Task

  alias BC.Acceptance
  alias BC.Acceptance.{Fixture, Report}

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
    unless BC.Provider.has_api_key?() do
      Mix.shell().error(
        "bc.accept: no API key. Copy config/secrets.env.example to config/secrets.env and paste ANTHROPIC_API_KEY (or set BC_API_KEY)."
      )

      halt(1)
    end

    kb = opts[:kb] || Fixture.kb_path()
    spec = opts[:spec] || Fixture.spec_path()
    tree = opts[:tree] || Fixture.tree_path()
    runs = opts[:runs] || 1

    unless File.dir?(kb) do
      Mix.shell().error("bc.accept: --kb is not a directory: #{kb}")
      halt(1)
    end

    unless File.exists?(spec) do
      Mix.shell().error("bc.accept: --spec not found: #{spec}")
      halt(1)
    end

    unless File.dir?(tree) do
      Mix.shell().error("bc.accept: --tree is not a directory: #{tree}")
      halt(1)
    end

    Mix.Task.run("app.start")
    put_live_env_defaults()

    results =
      Enum.map(1..runs, fn n ->
        Mix.shell().info("=== bc.accept run #{n}/#{runs} ===")
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
    BC.KB.Delta.render(proposal.deltas || [])
  end

  defp put_live_env_defaults do
    case BC.Provider.resolve(System.get_env()) do
      {:ok, resolved} ->
        unless System.get_env("BC_MODEL"), do: System.put_env("BC_MODEL", resolved.model)

        unless System.get_env("BC_API_BASE"),
          do: System.put_env("BC_API_BASE", resolved.api_base)

      _ ->
        unless System.get_env("BC_MODEL"), do: System.put_env("BC_MODEL", "claude-sonnet-4-5")

        unless System.get_env("BC_API_BASE"),
          do: System.put_env("BC_API_BASE", "https://api.anthropic.com/v1")
    end
  end

  defp halt(code) do
    halt_fn = Application.get_env(:bc, :halt, &System.halt/1)
    halt_fn.(code)
  end
end
