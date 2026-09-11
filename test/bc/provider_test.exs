defmodule BC.ProviderTest do
  use ExUnit.Case, async: true

  alias BC.Provider

  test "xai preset fills base, model, and XAI_API_KEY" do
    assert {:ok, resolved} =
             Provider.resolve(%{
               "BC_PROVIDER" => "xai",
               "XAI_API_KEY" => "xai-test"
             })

    assert resolved.provider == :xai
    assert resolved.api_base == "https://api.x.ai/v1"
    assert resolved.model == "grok-4"
    assert resolved.api_key == "xai-test"
  end

  test "grok is an alias for xai" do
    {:ok, resolved} =
      Provider.resolve(%{"BC_PROVIDER" => "grok", "XAI_API_KEY" => "k"})

    assert resolved.provider == :xai
  end

  test "anthropic preset fills Claude OpenAI-compat base and ANTHROPIC_API_KEY" do
    assert {:ok, resolved} =
             Provider.resolve(%{
               "BC_PROVIDER" => "anthropic",
               "ANTHROPIC_API_KEY" => "sk-ant-test"
             })

    assert resolved.provider == :anthropic
    assert resolved.api_base == "https://api.anthropic.com/v1"
    assert resolved.model == "claude-sonnet-4-5"
    assert resolved.api_key == "sk-ant-test"
    assert {"anthropic-version", "2023-06-01"} in Provider.headers(resolved.provider)
  end

  test "claude is an alias for anthropic" do
    {:ok, resolved} =
      Provider.resolve(%{"BC_PROVIDER" => "claude", "ANTHROPIC_API_KEY" => "k"})

    assert resolved.provider == :anthropic
  end

  test "BC_API_KEY wins over vendor keys" do
    {:ok, resolved} =
      Provider.resolve(%{
        "BC_PROVIDER" => "xai",
        "BC_API_KEY" => "bc-key",
        "XAI_API_KEY" => "xai-key"
      })

    assert resolved.api_key == "bc-key"
  end

  test "BC_MODEL overrides the preset default" do
    {:ok, resolved} =
      Provider.resolve(%{
        "BC_PROVIDER" => "xai",
        "XAI_API_KEY" => "k",
        "BC_MODEL" => "grok-4-fast"
      })

    assert resolved.model == "grok-4-fast"
  end

  test "infers xai from XAI_API_KEY when provider is unset" do
    {:ok, resolved} = Provider.resolve(%{"XAI_API_KEY" => "xai-k"})
    assert resolved.provider == :xai
    assert resolved.api_base == "https://api.x.ai/v1"
  end

  test "defaults to Claude when only a key is set" do
    {:ok, resolved} = Provider.resolve(%{"BC_API_KEY" => "sk-ant-k"})
    assert resolved.provider == :anthropic
    assert resolved.api_base == "https://api.anthropic.com/v1"
    assert resolved.model == "claude-sonnet-4-5"
    assert resolved.api_key == "sk-ant-k"
  end

  test "empty env defaults to Claude and asks for the key" do
    assert {:error, %{code: :missing_env, message: msg}} = Provider.resolve(%{})
    assert msg =~ "ANTHROPIC_API_KEY"
    assert msg =~ "config/secrets.env"
  end

  test "custom API base still requires BC_MODEL" do
    assert {:error, %{message: msg}} =
             Provider.resolve(%{
               "BC_API_KEY" => "k",
               "BC_API_BASE" => "http://localhost:1234/v1"
             })

    assert msg =~ "BC_MODEL"
  end

  test "loads key from an explicit secrets file" do
    path = Path.join(System.tmp_dir!(), "bc-secrets-#{System.unique_integer([:positive])}.env")

    try do
      File.write!(path, """
      # comment
      ANTHROPIC_API_KEY=from-file
      """)

      {:ok, resolved} = Provider.resolve(%{}, secrets_file: path)
      assert resolved.provider == :anthropic
      assert resolved.api_key == "from-file"
      assert resolved.model == "claude-sonnet-4-5"
    after
      File.rm(path)
    end
  end

  test "env wins over secrets file" do
    path = Path.join(System.tmp_dir!(), "bc-secrets-#{System.unique_integer([:positive])}.env")

    try do
      File.write!(path, "ANTHROPIC_API_KEY=from-file\n")

      {:ok, resolved} =
        Provider.resolve(%{"ANTHROPIC_API_KEY" => "from-env"}, secrets_file: path)

      assert resolved.api_key == "from-env"
    after
      File.rm(path)
    end
  end

  test "does not load config/secrets.env during tests" do
    assert {:error, %{code: :missing_env}} = Provider.resolve(%{})
  end
end
