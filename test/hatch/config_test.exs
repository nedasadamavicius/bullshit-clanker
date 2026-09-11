defmodule Hatch.ConfigTest do
  use ExUnit.Case

  describe "from_argv/1" do
    test "requires --kb flag" do
      assert {:error, %{code: :missing_kb}} = Hatch.Config.from_argv([])
    end

    test "rejects unknown flags" do
      assert {:error, %{code: :unknown_flag}} = Hatch.Config.from_argv(["--unknown"])
    end

    test "rejects unexpected arguments" do
      assert {:error, %{code: :invalid_args}} = Hatch.Config.from_argv(["arg"])
    end

    test "validates kb path exists" do
      assert {:error, %{code: :bad_kb}} = Hatch.Config.from_argv(["--kb", "/does/not/exist"])
    end

    test "validates kb path contains boards directory" do
      with_tmp_dir(fn dir ->
        assert {:error, %{code: :bad_kb}} = Hatch.Config.from_argv(["--kb", dir])
      end)
    end

    test "accepts valid kb with boards directory" do
      with_kb_dir(fn kb_dir ->
        original_env = set_required_env()

        try do
          result = Hatch.Config.from_argv(["--kb", kb_dir])
          assert {:ok, _config} = result
        after
          restore_env(original_env)
        end
      end)
    end

    test "accepts optional --tree flag" do
      original_env = set_required_env()

      try do
        with_kb_dir(fn kb_dir ->
          with_tmp_dir(fn tree_dir ->
            result = Hatch.Config.from_argv(["--kb", kb_dir, "--tree", tree_dir])
            assert {:ok, config} = result
            assert config.tree_root == Path.expand(tree_dir)
          end)
        end)
      after
        restore_env(original_env)
      end
    end

    test "rejects invalid tree path" do
      with_kb_dir(fn kb_dir ->
        result = Hatch.Config.from_argv(["--kb", kb_dir, "--tree", "/does/not/exist"])
        assert {:error, %{code: :bad_tree}} = result
      end)
    end
  end

  describe "from_env/2" do
    test "requires HATCH_MODEL" do
      with_kb_dir(fn kb_dir ->
        env = %{"HATCH_API_BASE" => "https://api.openai.com/v1", "HATCH_API_KEY" => "key"}
        result = Hatch.Config.from_env(env, kb: kb_dir)

        assert {:error, %{code: :missing_env, message: msg}} = result
        assert msg =~ "HATCH_MODEL"
      end)
    end

    test "requires HATCH_API_BASE" do
      with_kb_dir(fn kb_dir ->
        env = %{"HATCH_MODEL" => "gpt-4", "HATCH_API_KEY" => "key"}
        result = Hatch.Config.from_env(env, kb: kb_dir)

        assert {:error, %{code: :missing_env, message: msg}} = result
        assert msg =~ "HATCH_API_BASE"
      end)
    end

    test "requires HATCH_API_KEY" do
      with_kb_dir(fn kb_dir ->
        env = %{"HATCH_MODEL" => "gpt-4", "HATCH_API_BASE" => "https://api.openai.com/v1"}
        result = Hatch.Config.from_env(env, kb: kb_dir)

        assert {:error, %{code: :missing_env, message: msg}} = result
        assert msg =~ "HATCH_API_KEY"
      end)
    end

    test "uses HATCH_MODEL_INGEST default" do
      with_kb_dir(fn kb_dir ->
        env = %{
          "HATCH_MODEL" => "gpt-4",
          "HATCH_API_BASE" => "https://api.openai.com/v1",
          "HATCH_API_KEY" => "key"
        }

        {:ok, config} = Hatch.Config.from_env(env, kb: kb_dir)
        assert config.ingest_model == "gpt-4"
      end)
    end

    test "uses custom HATCH_MODEL_INGEST" do
      with_kb_dir(fn kb_dir ->
        env = %{
          "HATCH_MODEL" => "gpt-4",
          "HATCH_MODEL_INGEST" => "gpt-3.5-turbo",
          "HATCH_API_BASE" => "https://api.openai.com/v1",
          "HATCH_API_KEY" => "key"
        }

        {:ok, config} = Hatch.Config.from_env(env, kb: kb_dir)
        assert config.ingest_model == "gpt-3.5-turbo"
      end)
    end

    test "uses default tamago_go" do
      with_kb_dir(fn kb_dir ->
        env = %{
          "HATCH_MODEL" => "gpt-4",
          "HATCH_API_BASE" => "https://api.openai.com/v1",
          "HATCH_API_KEY" => "key"
        }

        {:ok, config} = Hatch.Config.from_env(env, kb: kb_dir)
        assert config.tamago_go == "tamago-go"
      end)
    end

    test "uses custom HATCH_TAMAGO_GO" do
      with_kb_dir(fn kb_dir ->
        env = %{
          "HATCH_MODEL" => "gpt-4",
          "HATCH_API_BASE" => "https://api.openai.com/v1",
          "HATCH_API_KEY" => "key",
          "HATCH_TAMAGO_GO" => "/usr/local/bin/tamago-go"
        }

        {:ok, config} = Hatch.Config.from_env(env, kb: kb_dir)
        assert config.tamago_go == "/usr/local/bin/tamago-go"
      end)
    end

    test "uses default build_timeout_ms" do
      with_kb_dir(fn kb_dir ->
        env = %{
          "HATCH_MODEL" => "gpt-4",
          "HATCH_API_BASE" => "https://api.openai.com/v1",
          "HATCH_API_KEY" => "key"
        }

        {:ok, config} = Hatch.Config.from_env(env, kb: kb_dir)
        assert config.build_timeout_ms == 120_000
      end)
    end

    test "uses custom HATCH_BUILD_TIMEOUT_MS" do
      with_kb_dir(fn kb_dir ->
        env = %{
          "HATCH_MODEL" => "gpt-4",
          "HATCH_API_BASE" => "https://api.openai.com/v1",
          "HATCH_API_KEY" => "key",
          "HATCH_BUILD_TIMEOUT_MS" => "60000"
        }

        {:ok, config} = Hatch.Config.from_env(env, kb: kb_dir)
        assert config.build_timeout_ms == 60_000
      end)
    end

    test "normalizes api_base by removing trailing slash" do
      with_kb_dir(fn kb_dir ->
        env = %{
          "HATCH_MODEL" => "gpt-4",
          "HATCH_API_BASE" => "https://api.openai.com/v1/",
          "HATCH_API_KEY" => "key"
        }

        {:ok, config} = Hatch.Config.from_env(env, kb: kb_dir)
        assert config.api_base == "https://api.openai.com/v1"
      end)
    end
  end

  describe "inspect/1" do
    test "redacts api_key" do
      with_kb_dir(fn kb_dir ->
        env = %{
          "HATCH_MODEL" => "gpt-4",
          "HATCH_API_BASE" => "https://api.openai.com/v1",
          "HATCH_API_KEY" => "secret-key-1234"
        }

        {:ok, config} = Hatch.Config.from_env(env, kb: kb_dir)
        inspected = inspect(config)

        refute inspected =~ "secret-key-1234"
        refute inspected =~ ":api_key"
      end)
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

  defp set_required_env do
    original = %{
      "HATCH_MODEL" => System.get_env("HATCH_MODEL"),
      "HATCH_API_BASE" => System.get_env("HATCH_API_BASE"),
      "HATCH_API_KEY" => System.get_env("HATCH_API_KEY")
    }

    System.put_env("HATCH_MODEL", "gpt-4")
    System.put_env("HATCH_API_BASE", "https://api.openai.com/v1")
    System.put_env("HATCH_API_KEY", "test-key")
    original
  end

  defp restore_env(original) do
    Enum.each(original, fn {key, val} ->
      if val, do: System.put_env(key, val), else: System.delete_env(key)
    end)
  end

  defp random_string(length) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> String.slice(0, length)
  end
end
