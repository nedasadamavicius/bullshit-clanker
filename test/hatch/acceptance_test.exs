defmodule Hatch.AcceptanceTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Hatch.Acceptance
  alias Hatch.Acceptance.{Fixture, Report}
  alias Hatch.Config
  alias Hatch.KB.Search
  alias Hatch.Model.Fake

  @moduletag :acceptance

  setup do
    previous_key = System.get_env("HATCH_API_KEY")
    previous_model = System.get_env("HATCH_MODEL")
    previous_base = System.get_env("HATCH_API_BASE")

    System.put_env("HATCH_MODEL", "gpt-4")
    System.put_env("HATCH_API_BASE", "https://api.openai.com/v1")
    System.put_env("HATCH_API_KEY", "test-key")

    Application.put_env(:hatch, :model_client, Hatch.Model.Fake)
    tree_before = Fixture.tree_hash(Fixture.tree_path())

    on_exit(fn ->
      restore_env("HATCH_API_KEY", previous_key)
      restore_env("HATCH_MODEL", previous_model)
      restore_env("HATCH_API_BASE", previous_base)

      if pid = Process.whereis(Hatch.Build.Worker) do
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      Hatch.BoardJob.DynamicSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn {_, child, _, _} ->
        if is_pid(child) do
          DynamicSupervisor.terminate_child(Hatch.BoardJob.DynamicSupervisor, child)
        end
      end)

      assert Fixture.tree_hash(Fixture.tree_path()) == tree_before
    end)

    {:ok, tree_before: tree_before}
  end

  test "CLI starts with --kb and no --tree; exits 2 without --kb" do
    capture_io(fn ->
      assert {:halted, 2} == catch_throw(Hatch.CLI.main([]))
    end)

    output =
      capture_io(fn ->
        assert {:halted, 0} ==
                 catch_throw(Hatch.CLI.main(["--kb", Fixture.kb_path()]))
      end)

    assert output =~ "hatch ready"
    assert output =~ "tree=none"
  end

  test "scripted run satisfies the v1 mechanism (criteria 2-7)", %{tree_before: tree_before} do
    output_dir = tmp_dir("out")

    assert {:ok, %{report: report, extras: extras}} =
             Acceptance.run(mode: :scripted, output_dir: output_dir)

    draft = extras.draft
    assert draft.soc == "imx6ul"
    assert draft.uart == "UART1"
    assert draft.ram_start == 0x80000000
    assert draft.ram_size == :unknown
    assert draft.tamago_board == :unknown

    events = extras.events

    search_summaries =
      events
      |> Enum.filter(&(&1.type == :tool_call_finished and &1.name == "kb.search"))
      |> Enum.map(&to_string(&1.summary))

    refute Enum.any?(search_summaries, &String.contains?(&1, Fixture.off_soc_id()))
    refute extras.proposal.nearest_board_id == Fixture.off_soc_id()

    assert Enum.any?(events, fn
             %{type: :tool_call_finished, name: "web_fetch", ok: false} -> true
             _ -> false
           end)

    assert Enum.any?(events, fn
             %{type: :tool_call_started, name: "kb.read", args: args} ->
               is_binary(args) and String.contains?(args, "/etc/passwd")

             _ ->
               false
           end)

    assert Enum.any?(events, fn
             %{type: :tool_call_finished, name: "kb.read", ok: false} -> true
             _ -> false
           end)

    {:ok, ranked} =
      Search.from_board(draft, exclude: [Fixture.held_out_id()], limit: 1)

    expected = hd(ranked).board.id
    assert extras.proposal.nearest_board_id == expected
    assert report.nearest_board == expected
    assert extras.proposal.deltas != []
    assert extras.proposal.citations != []
    assert report.citations_ok
    assert extras.proposal.patch != ""

    assert report.apply_ok
    patched = File.read!(Path.join(extras.scratch_tree, "board/fsl/board_a/board.go"))
    assert patched =~ "GPIO1_IO03"

    assert report.build_exit == 0
    assert extras.build_log =~ "GOOS=tamago"
    assert extras.build_log =~ "GOARCH=arm"
    assert extras.build_log =~ "GOARM=7"

    {:ok, json} = Report.read_json(Path.join(output_dir, "acceptance.json"))

    Enum.each(Report.fields(), fn field ->
      assert Map.has_key?(json, Atom.to_string(field))
    end)

    assert Report.passed?(report)
    assert Fixture.tree_hash(Fixture.tree_path()) == tree_before
  end

  test "inventing an uncited address in the script fails the citation check" do
    script = Fixture.load_script()
    mutated = mutate_patch(script, fn patch -> patch <> "+dead 0xDEADBEEF\n" end)

    assert {:error, %{report: report, extras: extras}} =
             Acceptance.run(
               mode: :scripted,
               script: mutated,
               output_dir: tmp_dir("bypass")
             )

    refute report.citations_ok
    refute report.apply_ok
    assert extras.proposal == nil
    assert Enum.any?(extras.events, &(&1.type == :proposal_invalid))
  end

  test "removing exclude: ranks the held-out board first" do
    script = Fixture.load_script()
    Application.put_env(:hatch, :fake_model, Fake.script_many(script.ingest))
    {:ok, spec} = File.read(Fixture.spec_path())
    {:ok, draft, _} = Hatch.Ingest.ingest(spec, "held-out")

    Hatch.Config.put(%Config{
      kb_root: Fixture.kb_path(),
      tree_root: nil,
      model: "fake",
      ingest_model: "fake",
      build_model: nil,
      api_base: "http://127.0.0.1/v1",
      api_key: "test",
      tamago_go: Fixture.fake_tamago_go(),
      build_timeout_ms: 15_000
    })

    Application.put_env(:hatch, :kb_root, Fixture.kb_path())
    {:ok, _} = Hatch.KB.Index.ensure_built()

    {:ok, with_exclude} =
      Search.from_board(draft, exclude: [Fixture.held_out_id()], limit: 3)

    {:ok, without} = Search.from_board(draft, exclude: [], limit: 3)

    refute hd(with_exclude).board.id == Fixture.held_out_id()
    assert hd(without).board.id == Fixture.held_out_id()
    refute Enum.any?(with_exclude, &(&1.board.id == Fixture.off_soc_id()))
    refute Enum.any?(without, &(&1.board.id == Fixture.off_soc_id()))
  end

  test "mix hatch.accept --help documents env and does not require a key" do
    previous = System.get_env("HATCH_API_KEY")
    System.delete_env("HATCH_API_KEY")

    output =
      capture_io(fn ->
        assert {:halted, 0} == catch_throw(Mix.Tasks.Hatch.Accept.run(["--help"]))
      end)

    assert output =~ "HATCH_API_KEY"
    assert output =~ "HATCH_TAMAGO_GO"

    restore_env("HATCH_API_KEY", previous)
  end

  test "mix hatch.accept refuses to run without HATCH_API_KEY" do
    previous = System.get_env("HATCH_API_KEY")
    System.delete_env("HATCH_API_KEY")

    output =
      capture_io(:stderr, fn ->
        assert {:halted, 1} == catch_throw(Mix.Tasks.Hatch.Accept.run([]))
      end)

    assert output =~ "HATCH_API_KEY"
    refute output =~ "hatch ready"

    restore_env("HATCH_API_KEY", previous)
  end

  test "a build exit 2 fails the run and lands in the report" do
    dir = tmp_dir("failgo")
    bin = Path.join(dir, "tamago-go")

    File.write!(bin, """
    #!/bin/sh
    echo "compiler boom"
    exit 2
    """)

    File.chmod!(bin, 0o755)

    assert {:error, %{report: report, extras: extras}} =
             Acceptance.run(
               mode: :scripted,
               tamago_go: bin,
               output_dir: Path.join(dir, "out")
             )

    assert report.apply_ok
    assert report.build_exit == 2
    assert extras.build_log =~ "compiler boom"
    refute Report.passed?(report)
  end

  defp mutate_patch(script, fun) do
    session =
      Enum.map(script.session, fn turn ->
        Enum.map(turn, fn
          {:tool_call, "propose_patch", args} ->
            {:tool_call, "propose_patch", Map.update!(args, "patch", fun)}

          other ->
            other
        end)
      end)

    %{script | session: session}
  end

  defp tmp_dir(label) do
    dir = Path.join(System.tmp_dir!(), "hatch_#{label}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)
end
