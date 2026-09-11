defmodule BC.Session.PromptTest do
  use ExUnit.Case

  alias BC.Config
  alias BC.KB.Board
  alias BC.Session.Prompt

  setup do
    config = %Config{
      kb_root: "/tmp/kb",
      tree_root: "/tmp/tree",
      model: "test",
      ingest_model: "test",
      build_model: nil,
      api_base: "http://localhost:8000",
      api_key: "test-key",
      tamago_go: "tamago-go",
      build_timeout_ms: 120_000
    }

    {:ok, config: config}
  end

  describe "system/2" do
    test "includes required keywords", %{config: config} do
      prompt = Prompt.system(config, nil)

      assert String.contains?(prompt, "unknown")
      assert String.contains?(prompt, "cite") || String.contains?(prompt, "citation")
      assert String.contains?(prompt, "cannot apply") || String.contains?(prompt, "Do not apply")
    end

    test "returns a non-empty string", %{config: config} do
      prompt = Prompt.system(config, nil)
      assert is_binary(prompt)
      assert String.length(prompt) > 100
    end

    test "includes KB boards section", %{config: config} do
      prompt = Prompt.system(config, nil)
      assert String.contains?(prompt, "KB Boards") || String.contains?(prompt, "boards")
    end

    test "includes draft facts when draft is provided", %{config: config} do
      draft = %Board{
        id: "my_board",
        source_path: "boards/my_board/board.toml",
        soc: "imx6ul",
        soc_key: nil,
        goarch: "arm",
        goarm: "7",
        ram_start: 0x80000000,
        ram_size: 0x20000000,
        uart: "UART2",
        peripherals: ["gpio", "usb"],
        pinmux: [],
        tamago_soc: "imx6",
        tamago_board: "mx6ulpico",
        schematic: "boards/my_board/schematic.pdf",
        tree: "github.com/test/tree",
        notes: "Test board",
        raw: %{}
      }

      prompt = Prompt.system(config, draft)

      assert String.contains?(prompt, "my_board")
      assert String.contains?(prompt, "imx6ul")
      assert String.contains?(prompt, "New Board")
    end

    test "does not include draft facts when draft is nil", %{config: config} do
      prompt = Prompt.system(config, nil)
      # Should not have the New Board section
      assert not String.contains?(prompt, "New Board (Draft)")
    end
  end
end
