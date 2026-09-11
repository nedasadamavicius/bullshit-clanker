defmodule BC.Acceptance do
  @moduledoc """
  V1 held-out acceptance runner (scripted and live).

  No new product behaviour — this is the harness around 001–012.
  """

  alias BC.Acceptance.{Fixture, Report}
  alias BC.Config
  alias BC.Events
  alias BC.Ingest
  alias BC.KB.Index
  alias BC.KB.Search
  alias BC.Model.Fake
  alias BC.Permit
  alias BC.Proposal
  alias BC.Proposal.Store
  alias BC.Session

  @turn_timeout_ms 15_000

  @spec run(keyword()) :: {:ok, map()} | {:error, map()}
  def run(opts \\ []) do
    mode = Keyword.get(opts, :mode, :scripted)
    start_ms = System.monotonic_time(:millisecond)

    kb_src = Keyword.get(opts, :kb, Fixture.kb_path())
    spec_path = Keyword.get(opts, :spec, Fixture.spec_path())
    tree_src = Keyword.get(opts, :tree, Fixture.tree_path())
    output_dir = Keyword.get(opts, :output_dir, File.cwd!())
    exclude? = Keyword.get(opts, :exclude, true)
    script = Keyword.get(opts, :script) || if(mode == :scripted, do: Fixture.load_script())

    kb_root = if mode == :scripted, do: Fixture.prepare_kb(kb_src), else: Path.expand(kb_src)
    tree_root = Fixture.prepare_tree(tree_src)

    exclude = if exclude?, do: [Fixture.held_out_id()], else: []
    previous_exclude = Application.get_env(:bc, :search_exclude)
    Application.put_env(:bc, :search_exclude, exclude)
    previous_applier = Application.get_env(:bc, :patch_applier)
    # Real apply — the harness is the human. Do not use the test seam.
    Application.put_env(:bc, :patch_applier, BC.Patch.Apply)

    try do
      config = build_config(mode, kb_root, tree_root, opts)
      BC.Config.put(config)
      Application.put_env(:bc, :kb_root, kb_root)
      Application.put_env(:bc, :tree_root, tree_root)

      {:ok, _} = Index.ensure_built()

      {:ok, spec_text} = File.read(spec_path)
      draft = ingest_draft(mode, spec_text, script)

      {:ok, expected_hits} = Search.from_board(draft, exclude: exclude, limit: 5)
      expected_board = expected_hits |> List.first() |> then(&(&1 && &1.board.id))

      {:ok, session_id, job_pid} = BC.BoardJob.Supervisor.start_session(config: config)
      :ok = Session.set_draft(session_id, draft)
      :ok = Events.subscribe(session_id)

      maybe_install_session_script(mode, script)

      Session.send_message(
        session_id,
        "Match this board against the KB and propose a patch against the nearest tree."
      )

      events = await_turn(@turn_timeout_ms)

      {proposal, citations_ok, uncited_tokens} =
        resolve_proposal(session_id, job_pid, events)

      nearest_board = proposal && proposal.nearest_board_id

      {apply_ok, apply_output} =
        maybe_apply(proposal, session_id, tree_root)

      {build_exit, build_log} =
        maybe_build(session_id, config, draft, apply_ok)

      report =
        Report.new(%{
          nearest_board: nearest_board,
          expected_board: expected_board,
          citations_ok: citations_ok,
          uncited_tokens: uncited_tokens,
          apply_ok: apply_ok,
          build_exit: build_exit,
          duration_ms: System.monotonic_time(:millisecond) - start_ms,
          usage: Session.usage(session_id)
        })

      Report.write_json(Path.join(output_dir, "acceptance.json"), report)

      extras = %{
        events: events,
        draft: draft,
        proposal: proposal,
        expected_hits: expected_hits,
        apply_output: apply_output,
        build_log: build_log,
        scratch_tree: tree_root,
        kb_root: kb_root,
        session_id: session_id,
        exclude: exclude
      }

      if Report.passed?(report) do
        {:ok, %{report: report, extras: extras}}
      else
        {:error, %{report: report, extras: extras}}
      end
    after
      restore_env(:search_exclude, previous_exclude)
      restore_env(:patch_applier, previous_applier)
    end
  end

  defp build_config(:scripted, kb_root, tree_root, opts) do
    %Config{
      kb_root: kb_root,
      tree_root: tree_root,
      model: "fake",
      ingest_model: "fake",
      build_model: nil,
      api_base: "http://127.0.0.1/v1",
      api_key: "test",
      tamago_go: Keyword.get(opts, :tamago_go, Fixture.fake_tamago_go()),
      build_timeout_ms: Keyword.get(opts, :build_timeout_ms, 15_000)
    }
  end

  defp build_config(:live, kb_root, tree_root, _opts) do
    {:ok, config} =
      Config.from_env(System.get_env(), kb: kb_root, tree: tree_root)

    %{config | kb_root: kb_root, tree_root: tree_root}
  end

  defp ingest_draft(:scripted, spec_text, script) do
    ingest_turns = Map.get(script, :ingest) || script["ingest"]
    Application.put_env(:bc, :fake_model, Fake.script_many(ingest_turns))
    {:ok, draft, _conflicts} = Ingest.ingest(spec_text, "held-out")
    draft
  end

  defp ingest_draft(:live, spec_text, _script) do
    {:ok, draft, _conflicts} = Ingest.ingest(spec_text, "held-out")
    draft
  end

  defp maybe_install_session_script(:scripted, script) do
    session_turns = Map.get(script, :session) || script["session"]
    Application.put_env(:bc, :fake_model, Fake.script_many(session_turns))
    :ok
  end

  defp maybe_install_session_script(:live, _), do: :ok

  defp await_turn(timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_turn([], deadline)
  end

  defp do_await_turn(acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:bc_event, event} ->
          acc = [event | acc]

          if event.type == :turn_finished do
            Enum.reverse(acc)
          else
            do_await_turn(acc, deadline)
          end
      after
        max(remaining, 1) ->
          Enum.reverse(acc)
      end
    end
  end

  defp resolve_proposal(session_id, job_pid, events) do
    store = BC.BoardJob.Supervisor.get_proposal_store(job_pid)

    case Store.pending(store, session_id) do
      {:ok, proposal} ->
        {proposal, true, []}

      :none ->
        invalid = Enum.filter(events, &(&1.type == :proposal_invalid))
        tokens = Enum.flat_map(invalid, &uncited_from_reasons(&1[:reasons] || []))
        {nil, false, tokens}
    end
  end

  defp uncited_from_reasons(reasons) do
    reasons
    |> List.wrap()
    |> Enum.flat_map(fn
      reason when is_binary(reason) ->
        Regex.scan(~r/0x[0-9a-fA-F]{3,}/, reason) |> Enum.map(&hd/1)

      _ ->
        []
    end)
  end

  defp maybe_apply(nil, _session_id, _tree_root), do: {false, "no proposal"}

  defp maybe_apply(proposal, session_id, tree_root) do
    # Harness is the operator (spec 013). Live entry is mix bc.accept;
    # both files are excluded from the 009 Permit.mint grep.
    permit = Permit.mint(proposal.id, session_id, Proposal.patch_hash(proposal))

    case BC.Patch.Apply.apply_patch(proposal, permit, tree_root) do
      {:ok, result} -> {true, result.output}
      {:error, err} -> {false, err.message}
    end
  end

  defp maybe_build(_session_id, _config, _draft, false), do: {1, "skipped; apply failed"}

  defp maybe_build(session_id, config, draft, true) do
    ensure_builder(config)

    goarch = if is_binary(draft.goarch), do: draft.goarch, else: "arm"
    goarm = if is_binary(draft.goarm), do: draft.goarm, else: "7"

    case BC.Build.Worker.build(session_id,
           package: "./...",
           timeout_ms: config.build_timeout_ms,
           goarch: goarch,
           goarm: goarm
         ) do
      {:ok, result} -> {result.exit_status, result.log}
      {:error, err} -> {1, err.message}
    end
  end

  defp ensure_builder(config) do
    if pid = Process.whereis(BC.Build.Worker) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end

    {:ok, _pid} = BC.Build.Worker.start_link(config: config)
    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:bc, key)
  defp restore_env(key, value), do: Application.put_env(:bc, key, value)
end
