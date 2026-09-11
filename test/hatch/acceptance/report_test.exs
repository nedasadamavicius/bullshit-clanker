defmodule Hatch.Acceptance.ReportTest do
  use ExUnit.Case, async: true

  alias Hatch.Acceptance.Report

  @moduletag :acceptance

  test "new/1 fills every acceptance.json field" do
    report = Report.new(%{nearest_board: "a", expected_board: "a", citations_ok: true})
    Enum.each(Report.fields(), fn field -> assert Map.has_key?(report, field) end)
  end

  test "passed?/1 requires nearest, citations, apply, and build 0" do
    good =
      Report.new(%{
        nearest_board: "imx6ul_board_a",
        expected_board: "imx6ul_board_a",
        citations_ok: true,
        apply_ok: true,
        build_exit: 0
      })

    assert Report.passed?(good)
    refute Report.passed?(Report.new(Map.put(good, :build_exit, 2)))
    refute Report.passed?(Report.new(Map.put(good, :apply_ok, false)))
    refute Report.passed?(Report.new(Map.put(good, :citations_ok, false)))
    refute Report.passed?(Report.new(Map.put(good, :nearest_board, "other")))
  end

  test "write_json/2 and read_json/1 round-trip every field" do
    dir = Path.join(System.tmp_dir!(), "hatch_report_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "acceptance.json")

    report =
      Report.new(%{
        nearest_board: "imx6ul_board_a",
        expected_board: "imx6ul_board_a",
        citations_ok: true,
        uncited_tokens: [],
        apply_ok: true,
        build_exit: 0,
        duration_ms: 12,
        usage: %{"prompt_tokens" => 1}
      })

    :ok = Report.write_json(path, report)
    {:ok, decoded} = Report.read_json(path)

    Enum.each(Report.fields(), fn field ->
      assert Map.has_key?(decoded, Atom.to_string(field))
    end)

    File.rm_rf!(dir)
  end
end
