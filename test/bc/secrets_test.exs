defmodule BC.SecretsTest do
  use ExUnit.Case, async: true

  alias BC.Secrets

  test "parses KEY=VALUE, comments, export prefix, and quotes" do
    parsed =
      Secrets.parse("""
      # a comment
      ANTHROPIC_API_KEY=sk-ant-plain
      export BC_MODEL=claude-sonnet-4-5
      BC_API_BASE="https://api.anthropic.com/v1"
      api_key='ignored-because-later-wins'
      """)

    assert parsed["ANTHROPIC_API_KEY"] == "sk-ant-plain"
    assert parsed["BC_MODEL"] == "claude-sonnet-4-5"
    assert parsed["BC_API_BASE"] == "https://api.anthropic.com/v1"
    assert parsed["BC_API_KEY"] == "ignored-because-later-wins"
  end

  test "load returns empty map when the file is missing" do
    assert Secrets.load("/does/not/exist.env") == %{}
  end

  test "load reads a file from disk" do
    path = Path.join(System.tmp_dir!(), "bc-secrets-#{System.unique_integer([:positive])}.env")

    try do
      File.write!(path, "ANTHROPIC_API_KEY=disk-key\n")
      assert Secrets.load(path) == %{"ANTHROPIC_API_KEY" => "disk-key"}
    after
      File.rm(path)
    end
  end
end
