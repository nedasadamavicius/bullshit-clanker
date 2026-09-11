defmodule BC.CLITest do
  use ExUnit.Case
  import ExUnit.CaptureIO

  describe "main/1" do
    test "exits 2 when no --kb provided" do
      assert_exit_2(fn ->
        BC.CLI.main([])
      end)
    end

    test "exits 2 when --kb path does not exist" do
      assert_exit_2(fn ->
        BC.CLI.main(["--kb", "/does/not/exist"])
      end)
    end

    test "exits 2 when --kb has no boards directory" do
      with_tmp_dir(fn dir ->
        assert_exit_2(fn ->
          BC.CLI.main(["--kb", dir])
        end)
      end)
    end

    test "exits 2 when --tree path does not exist" do
      with_kb_dir(fn kb_dir ->
        assert_exit_2(fn ->
          BC.CLI.main(["--kb", kb_dir, "--tree", "/does/not/exist"])
        end)
      end)
    end

    test "exits 2 when required env vars are missing" do
      with_kb_dir(fn kb_dir ->
        keys = ["BC_MODEL", "BC_API_BASE", "BC_API_KEY", "ANTHROPIC_API_KEY", "XAI_API_KEY"]
        original = Map.new(keys, &{&1, System.get_env(&1)})

        try do
          Enum.each(keys, &System.delete_env/1)

          assert_exit_2(fn ->
            BC.CLI.main(["--kb", kb_dir])
          end)
        after
          Enum.each(original, fn
            {k, nil} -> System.delete_env(k)
            {k, v} -> System.put_env(k, v)
          end)
        end
      end)
    end

    test "exits 0 and prints banner with valid config" do
      original_env = set_required_env()

      try do
        with_kb_dir(fn kb_dir ->
          # Create one example board
          boards_dir = Path.join(kb_dir, "boards")
          example_dir = Path.join(boards_dir, "example")
          File.mkdir_p!(example_dir)
          File.write!(Path.join(example_dir, "board.toml"), "")

          output =
            capture_io(fn ->
              try do
                BC.CLI.main(["--kb", kb_dir])
              catch
                {:halted, 0} -> :ok
              end
            end)

          assert output =~ "bc ready"
          assert output =~ "boards=1"
          assert output =~ kb_dir
        end)
      after
        restore_env(original_env)
      end
    end

    test "prints banner with tree path when provided" do
      original_env = set_required_env()

      try do
        with_kb_dir(fn kb_dir ->
          with_tmp_dir(fn tree_dir ->
            boards_dir = Path.join(kb_dir, "boards")
            example_dir = Path.join(boards_dir, "example")
            File.mkdir_p!(example_dir)
            File.write!(Path.join(example_dir, "board.toml"), "")

            output =
              capture_io(fn ->
                try do
                  BC.CLI.main(["--kb", kb_dir, "--tree", tree_dir])
                catch
                  {:halted, 0} -> :ok
                end
              end)

            assert output =~ tree_dir
            refute output =~ "tree=none"
          end)
        end)
      after
        restore_env(original_env)
      end
    end

    test "prints tree=none when no tree provided" do
      original_env = set_required_env()

      try do
        with_kb_dir(fn kb_dir ->
          boards_dir = Path.join(kb_dir, "boards")
          example_dir = Path.join(boards_dir, "example")
          File.mkdir_p!(example_dir)
          File.write!(Path.join(example_dir, "board.toml"), "")

          output =
            capture_io(fn ->
              try do
                BC.CLI.main(["--kb", kb_dir])
              catch
                {:halted, 0} -> :ok
              end
            end)

          assert output =~ "tree=none"
        end)
      after
        restore_env(original_env)
      end
    end
  end

  defp assert_exit_2(fun) do
    try do
      fun.()
      flunk("Expected halt with code 2")
    catch
      {:halted, 2} ->
        :ok
    end
  end

  defp with_tmp_dir(fun) do
    tmp_dir = System.tmp_dir!() <> "/" <> random_string(8)
    File.mkdir_p!(tmp_dir)

    try do
      fun.(tmp_dir)
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp with_kb_dir(fun) do
    with_tmp_dir(fn tmp_dir ->
      kb_dir = Path.join(tmp_dir, "kb")
      File.mkdir_p!(Path.join(kb_dir, "boards"))
      fun.(kb_dir)
    end)
  end

  defp random_string(length) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> String.slice(0, length)
  end

  defp set_required_env do
    original = %{
      "BC_MODEL" => System.get_env("BC_MODEL"),
      "BC_API_BASE" => System.get_env("BC_API_BASE"),
      "BC_API_KEY" => System.get_env("BC_API_KEY")
    }

    System.put_env("BC_MODEL", "gpt-4")
    System.put_env("BC_API_BASE", "https://api.openai.com/v1")
    System.put_env("BC_API_KEY", "test-key")
    original
  end

  defp restore_env(original) do
    Enum.each(original, fn {key, val} ->
      if val, do: System.put_env(key, val), else: System.delete_env(key)
    end)
  end
end
