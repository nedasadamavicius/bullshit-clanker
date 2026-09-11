defmodule Hatch.Tools.ProposeTest do
  use ExUnit.Case
  alias Hatch.Proposal.Store
  alias Hatch.Tools.ReadLog

  setup do
    read_log = ReadLog.new()
    proposal_store = Store.new()
    {:ok, read_log: read_log, proposal_store: proposal_store}
  end

  describe "proposal store" do
    test "stores and retrieves proposals", %{proposal_store: proposal_store} do
      proposal = %Hatch.Proposal{
        id: "p_test1",
        session_id: "s_test",
        nearest_board_id: "mk2",
        summary: "Test proposal",
        deltas: [],
        citations: [%{path: "boards/mk2/board.toml", claim: "test"}],
        patch: "--- a/file.go\n+++ b/file.go\n@@ -1 +1 @@\n-old\n+new\n",
        status: :pending,
        invalid_reasons: [],
        created_at: DateTime.utc_now()
      }

      Store.put(proposal_store, proposal)

      {:ok, retrieved} = Store.get(proposal_store, "s_test", "p_test1")
      assert retrieved.id == "p_test1"
      assert retrieved.status == :pending

      {:ok, pending} = Store.pending(proposal_store, "s_test")
      assert pending.id == "p_test1"
    end

    test "supersedes previous pending proposal", %{proposal_store: proposal_store} do
      proposal1 = %Hatch.Proposal{
        id: "p_test1",
        session_id: "s_test",
        nearest_board_id: "mk2",
        summary: "First proposal",
        deltas: [],
        citations: [%{path: "boards/mk2/board.toml", claim: "test"}],
        patch: "--- a/file.go\n+++ b/file.go\n@@ -1 +1 @@\n-old1\n+new1\n",
        status: :pending,
        invalid_reasons: [],
        created_at: DateTime.utc_now()
      }

      proposal2 = %Hatch.Proposal{
        id: "p_test2",
        session_id: "s_test",
        nearest_board_id: "mk2",
        summary: "Second proposal",
        deltas: [],
        citations: [%{path: "boards/mk2/board.toml", claim: "test"}],
        patch: "--- a/file.go\n+++ b/file.go\n@@ -1 +1 @@\n-old2\n+new2\n",
        status: :pending,
        invalid_reasons: [],
        created_at: DateTime.utc_now()
      }

      Store.put(proposal_store, proposal1)
      assert {:ok, p} = Store.pending(proposal_store, "s_test")
      assert p.id == "p_test1"

      Store.put(proposal_store, proposal2)
      Store.set_status(proposal_store, "s_test", "p_test1", :rejected, ["superseded"])

      assert {:ok, p} = Store.pending(proposal_store, "s_test")
      assert p.id == "p_test2"

      {:ok, old} = Store.get(proposal_store, "s_test", "p_test1")
      assert old.status == :rejected
      assert "superseded" in old.invalid_reasons
    end

    test "returns :none when no pending proposal", %{proposal_store: proposal_store} do
      assert :none = Store.pending(proposal_store, "s_test")
    end

    test "can set proposal status", %{proposal_store: proposal_store} do
      proposal = %Hatch.Proposal{
        id: "p_test1",
        session_id: "s_test",
        nearest_board_id: "mk2",
        summary: "Test",
        deltas: [],
        citations: [],
        patch: "patch",
        status: :pending,
        invalid_reasons: [],
        created_at: DateTime.utc_now()
      }

      Store.put(proposal_store, proposal)
      Store.set_status(proposal_store, "s_test", "p_test1", :applied, [])

      {:ok, updated} = Store.get(proposal_store, "s_test", "p_test1")
      assert updated.status == :applied
    end
  end

  describe "patch parsing validation" do
    test "tool schema is well-formed" do
      import Hatch.Tools

      config = %Hatch.Config{
        kb_root: "/tmp/kb",
        tree_root: nil,
        model: "gpt-4",
        ingest_model: "gpt-4",
        build_model: nil,
        api_base: "https://api.openai.com",
        api_key: "test",
        tamago_go: "tamago-go",
        build_timeout_ms: 120_000
      }

      schemas = schemas(config)
      # Should have propose_patch schema
      propose_schemas = Enum.filter(schemas, &(&1["function"]["name"] == "propose_patch"))
      assert length(propose_schemas) == 1

      schema = Enum.at(propose_schemas, 0)
      assert schema["function"]["name"] == "propose_patch"
      assert schema["function"]["description"] != nil

      # Check that all required fields are in the schema
      required = schema["function"]["parameters"]["required"]
      assert "nearest_board_id" in required
      assert "summary" in required
      assert "patch" in required
      assert "citations" in required
    end
  end
end
