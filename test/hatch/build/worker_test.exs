defmodule Hatch.Build.WorkerTest do
  use ExUnit.Case, async: false

  describe "validation" do
    test "returns error when package starts with dash" do
      config = make_config("echo")
      start_supervised!({Hatch.Build.Worker, [config: config]})

      result = Hatch.Build.Worker.build("session123", package: "-invalid")

      assert {:error, %{code: :invalid_args}} = result
    end

    test "returns error when timeout_ms is invalid" do
      config = make_config("echo")
      start_supervised!({Hatch.Build.Worker, [config: config]})

      result =
        Hatch.Build.Worker.build("session123", package: "github.com/example/pkg", timeout_ms: -1)

      assert {:error, %{code: :invalid_args}} = result
    end

    test "handles missing toolchain" do
      config = make_config("/nonexistent/tamago-go")
      start_supervised!({Hatch.Build.Worker, [config: config]})

      result = Hatch.Build.Worker.build("session123", package: "test")

      assert {:error, %{code: :no_toolchain}} = result
    end
  end

  describe "fake toolchain integration" do
    test "successful build" do
      fake_dir = tmp_build_dir()
      fake_bin = Path.join(fake_dir, "tamago-go")

      File.write!(fake_bin, """
      #!/bin/sh
      echo "Building..."
      echo "Success"
      exit 0
      """)

      File.chmod!(fake_bin, 0o755)

      config = make_config(fake_bin)
      start_supervised!({Hatch.Build.Worker, [config: config]})

      result = Hatch.Build.Worker.build("session123", package: "test")

      assert {:ok, output} = result
      assert output.exit_status == 0
      assert output.timed_out == false
      assert Map.has_key?(output, :build_id)
      assert Map.has_key?(output, :duration_ms)
      assert Map.has_key?(output, :log)

      cleanup_tmp_dir(fake_dir)
    end

    test "non-zero exit" do
      fake_dir = tmp_build_dir()
      fake_bin = Path.join(fake_dir, "tamago-go")

      File.write!(fake_bin, """
      #!/bin/sh
      echo "Compilation failed"
      exit 2
      """)

      File.chmod!(fake_bin, 0o755)

      config = make_config(fake_bin)
      start_supervised!({Hatch.Build.Worker, [config: config]})

      result = Hatch.Build.Worker.build("session123", package: "test")

      assert {:ok, output} = result
      assert output.exit_status == 2
      assert output.timed_out == false
      assert String.contains?(output.log, "Compilation failed")

      cleanup_tmp_dir(fake_dir)
    end

    @tag :slow
    test "timeout handling" do
      fake_dir = tmp_build_dir()
      fake_bin = Path.join(fake_dir, "tamago-go")

      File.write!(fake_bin, """
      #!/bin/sh
      sleep 10
      exit 0
      """)

      File.chmod!(fake_bin, 0o755)

      config = make_config(fake_bin)
      start_supervised!({Hatch.Build.Worker, [config: config]})

      result = Hatch.Build.Worker.build("session123", timeout_ms: 500, package: "test")

      assert {:ok, output} = result
      assert output.exit_status == 124
      assert output.timed_out == true

      cleanup_tmp_dir(fake_dir)
    end

    test "broadcasts events" do
      fake_dir = tmp_build_dir()
      fake_bin = Path.join(fake_dir, "tamago-go")

      File.write!(fake_bin, """
      #!/bin/sh
      echo "Output line 1"
      echo "Output line 2"
      exit 0
      """)

      File.chmod!(fake_bin, 0o755)

      config = make_config(fake_bin)
      start_supervised!({Hatch.Build.Worker, [config: config]})

      session_id = "session_#{System.unique_integer()}"

      # Subscribe to events
      Phoenix.PubSub.subscribe(Hatch.PubSub, "session:#{session_id}")

      result = Hatch.Build.Worker.build(session_id, package: "test")

      assert {:ok, _output} = result

      # Collect events
      events = collect_events([])

      # Should have at least build_started and build_finished
      event_types = Enum.map(events, & &1.type)
      assert :build_started in event_types
      assert :build_finished in event_types

      cleanup_tmp_dir(fake_dir)
    end
  end

  defp collect_events(acc) do
    receive do
      {:hatch_event, event} ->
        collect_events([event | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defp make_config(tamago_go_bin) do
    tree_root = Path.join(System.tmp_dir!(), "hatch_test_tree_#{System.unique_integer()}")
    File.mkdir_p!(tree_root)

    %Hatch.Config{
      kb_root: Path.join(System.tmp_dir!(), "hatch_test_kb_#{System.unique_integer()}"),
      tree_root: tree_root,
      model: "test-model",
      ingest_model: "test-ingest",
      build_model: nil,
      api_base: "http://test",
      api_key: "test-key",
      tamago_go: tamago_go_bin,
      build_timeout_ms: 120_000
    }
  end

  defp tmp_build_dir do
    dir = Path.join(System.tmp_dir!(), "hatch_build_test_#{System.unique_integer()}")
    File.mkdir_p!(dir)
    dir
  end

  defp cleanup_tmp_dir(dir) do
    File.rm_rf!(dir)
  end
end
