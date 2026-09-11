defmodule BC.KB.IndexTest do
  use ExUnit.Case

  alias BC.KB.Index
  alias BC.Config

  setup do
    fixtures = Path.expand("../../fixtures", __DIR__)

    on_exit(fn ->
      try do
        :ets.delete(:bc_kb)
      rescue
        _ -> :ok
      end
    end)

    {:ok, fixtures: fixtures}
  end

  test "ensure_built loads boards and creates ETS", %{fixtures: fixtures} do
    kb_root = Path.join(fixtures, "kb_good")

    config = %Config{
      kb_root: kb_root,
      tree_root: nil,
      model: "gpt-4",
      ingest_model: "gpt-4",
      build_model: nil,
      api_base: "https://api.openai.com/v1",
      api_key: "fake-key",
      tamago_go: "tamago-go",
      build_timeout_ms: 120_000
    }

    Config.put(config)

    {:ok, result} = Index.ensure_built()

    assert result.boards == 2
    assert is_boolean(result.rebuilt)

    all_boards = Index.all()
    assert length(all_boards) == 2

    ids = Enum.map(all_boards, & &1.id)
    assert "mk1" in ids
    assert "mk2" in ids
  end

  test "get returns board by id", %{fixtures: fixtures} do
    kb_root = Path.join(fixtures, "kb_good")

    config = %Config{
      kb_root: kb_root,
      tree_root: nil,
      model: "gpt-4",
      ingest_model: "gpt-4",
      build_model: nil,
      api_base: "https://api.openai.com/v1",
      api_key: "fake-key",
      tamago_go: "tamago-go",
      build_timeout_ms: 120_000
    }

    Config.put(config)

    Index.ensure_built()

    {:ok, board} = Index.get("mk1")
    assert board.id == "mk1"
    assert board.soc == "imx6ul"
  end

  test "get returns error for unknown board", %{fixtures: fixtures} do
    kb_root = Path.join(fixtures, "kb_good")

    config = %Config{
      kb_root: kb_root,
      tree_root: nil,
      model: "gpt-4",
      ingest_model: "gpt-4",
      build_model: nil,
      api_base: "https://api.openai.com/v1",
      api_key: "fake-key",
      tamago_go: "tamago-go",
      build_timeout_ms: 120_000
    }

    Config.put(config)

    Index.ensure_built()

    {:error, :not_found} = Index.get("nonexistent")
  end

  test "sqlite index is created and persisted", %{fixtures: fixtures} do
    kb_root = Path.join(fixtures, "kb_imx")
    db_path = Path.join(kb_root, "index.sqlite")

    File.rm(db_path)

    config = %Config{
      kb_root: kb_root,
      tree_root: nil,
      model: "gpt-4",
      ingest_model: "gpt-4",
      build_model: nil,
      api_base: "https://api.openai.com/v1",
      api_key: "fake-key",
      tamago_go: "tamago-go",
      build_timeout_ms: 120_000
    }

    Config.put(config)

    {:ok, result} = Index.ensure_built()

    assert File.exists?(db_path)
    assert result.rebuilt == true

    {:ok, result2} = Index.ensure_built()
    assert result2.rebuilt == false
  end

  test "deleting index.sqlite and restarting produces identical results", %{fixtures: fixtures} do
    kb_root = Path.join(fixtures, "kb_imx")
    db_path = Path.join(kb_root, "index.sqlite")

    File.rm(db_path)

    config = %Config{
      kb_root: kb_root,
      tree_root: nil,
      model: "gpt-4",
      ingest_model: "gpt-4",
      build_model: nil,
      api_base: "https://api.openai.com/v1",
      api_key: "fake-key",
      tamago_go: "tamago-go",
      build_timeout_ms: 120_000
    }

    Config.put(config)

    {:ok, _} = Index.ensure_built()
    boards1 = Index.all() |> Enum.map(& &1.id) |> Enum.sort()

    File.rm(db_path)

    {:ok, _} = Index.ensure_built()
    boards2 = Index.all() |> Enum.map(& &1.id) |> Enum.sort()

    assert boards1 == boards2
  end
end
