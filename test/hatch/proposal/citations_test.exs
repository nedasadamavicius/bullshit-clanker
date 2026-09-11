defmodule Hatch.Proposal.CitationsTest do
  use ExUnit.Case
  alias Hatch.Proposal
  alias Hatch.Proposal.Citations
  alias Hatch.Tools.ReadLog

  setup do
    read_log = ReadLog.new()
    {:ok, read_log: read_log}
  end

  describe "check/2 validation rules" do
    test "rejects empty citations", %{read_log: read_log} do
      proposal = %Proposal{
        citations: [],
        patch: "+0x400a8000\n"
      }

      ctx = %{session_id: "s_test", read_log: read_log, kb_root: "/kb"}

      assert {:error, err} = Citations.check(proposal, ctx)
      assert err.code == :uncited_claim
    end

    test "checks that cited paths exist" do
      read_log = ReadLog.new()
      # Don't create actual KB files for this test

      proposal = %Proposal{
        citations: [%{path: "boards/mk2/board.toml", claim: "0x400a8000"}],
        patch: "+0x400a8000\n"
      }

      Application.put_env(:hatch, :kb_root, "/nonexistent/kb")

      ctx = %{session_id: "s_test", read_log: read_log, kb_root: "/nonexistent/kb"}

      try do
        # Will fail because path doesn't exist
        assert {:error, err} = Citations.check(proposal, ctx)
        assert err.code == :uncited_claim
      after
        Application.delete_env(:hatch, :kb_root)
      end
    end

    test "checks that cited paths were read in session", %{read_log: read_log} do
      # Don't log the path to read_log
      proposal = %Proposal{
        citations: [%{path: "boards/mk2/board.toml", claim: "0x400a8000"}],
        patch: "+0x400a8000\n"
      }

      Application.put_env(:hatch, :kb_root, "/kb")

      ctx = %{session_id: "s_test", read_log: read_log, kb_root: "/kb"}

      try do
        # Will fail because path wasn't read
        assert {:error, err} = Citations.check(proposal, ctx)
        assert err.code == :uncited_claim
      after
        Application.delete_env(:hatch, :kb_root)
      end
    end
  end

  describe "claim token extraction and matching" do
    test "detects uncited hex literals", %{read_log: read_log} do
      # Set up a read file
      ReadLog.log(read_log, "boards/mk2/board.toml", "kb.read")

      proposal = %Proposal{
        citations: [%{path: "boards/mk2/board.toml", claim: "some other address"}],
        patch: "+#define RAM_START 0x400a8000\n"
      }

      # Create a temporary file so it exists
      File.mkdir_p!("boards/mk2")
      File.write!("boards/mk2/board.toml", "# temp")

      Application.put_env(:hatch, :kb_root, File.cwd!())

      ctx = %{
        session_id: "s_test",
        read_log: read_log,
        kb_root: File.cwd!()
      }

      try do
        assert {:error, err} = Citations.check(proposal, ctx)
        assert err.code == :uncited_claim
        assert String.contains?(err.message, "0x400a8000")
      after
        File.rm!("boards/mk2/board.toml")
        File.rmdir!("boards/mk2")
        Application.delete_env(:hatch, :kb_root)
      end
    end

    test "accepts cited hex literals", %{read_log: read_log} do
      ReadLog.log(read_log, "boards/mk2/board.toml", "kb.read")

      proposal = %Proposal{
        citations: [%{path: "boards/mk2/board.toml", claim: "RAM_START 0x400a8000"}],
        patch: "+#define RAM_START 0x400a8000\n"
      }

      File.mkdir_p!("boards/mk2")
      File.write!("boards/mk2/board.toml", "# temp")

      Application.put_env(:hatch, :kb_root, File.cwd!())

      ctx = %{
        session_id: "s_test",
        read_log: read_log,
        kb_root: File.cwd!()
      }

      try do
        assert :ok = Citations.check(proposal, ctx)
      after
        File.rm!("boards/mk2/board.toml")
        File.rmdir!("boards/mk2")
        Application.delete_env(:hatch, :kb_root)
      end
    end

    test "detects uncited pin identifiers", %{read_log: read_log} do
      ReadLog.log(read_log, "boards/mk2/board.toml", "kb.read")

      # Pin identifiers are only detected on lines with pinmux/pad/uart keywords
      proposal = %Proposal{
        citations: [%{path: "boards/mk2/board.toml", claim: "some address"}],
        patch: "+\tpadmux: {signal: GPIO_1, pad: GPIO_MUX_4}\n"
      }

      File.mkdir_p!("boards/mk2")
      File.write!("boards/mk2/board.toml", "# temp")

      Application.put_env(:hatch, :kb_root, File.cwd!())

      ctx = %{
        session_id: "s_test",
        read_log: read_log,
        kb_root: File.cwd!()
      }

      try do
        assert {:error, err} = Citations.check(proposal, ctx)
        assert err.code == :uncited_claim
        # The token should be captured
        assert String.contains?(err.message, "GPIO_") or String.contains?(err.message, "claim(s)")
      after
        File.rm!("boards/mk2/board.toml")
        File.rmdir!("boards/mk2")
        Application.delete_env(:hatch, :kb_root)
      end
    end

    test "patch with no claim tokens still requires citations", %{read_log: read_log} do
      ReadLog.log(read_log, "boards/mk2/board.toml", "kb.read")

      proposal = %Proposal{
        citations: [%{path: "boards/mk2/board.toml", claim: "general comment"}],
        patch: "+// This is a comment\n+// No addresses or pins\n"
      }

      File.mkdir_p!("boards/mk2")
      File.write!("boards/mk2/board.toml", "# temp")

      Application.put_env(:hatch, :kb_root, File.cwd!())

      ctx = %{
        session_id: "s_test",
        read_log: read_log,
        kb_root: File.cwd!()
      }

      try do
        assert :ok = Citations.check(proposal, ctx)
      after
        File.rm!("boards/mk2/board.toml")
        File.rmdir!("boards/mk2")
        Application.delete_env(:hatch, :kb_root)
      end
    end
  end

  describe "PRODUCT.md failure case" do
    test "rejects invented 0x400A8000 address (case insensitive)", %{read_log: read_log} do
      ReadLog.log(read_log, "boards/mk2/board.toml", "kb.read")

      # This is the exact case from PRODUCT.md: the model invents an address from training data
      proposal = %Proposal{
        citations: [%{path: "boards/mk2/board.toml", claim: "I read this file"}],
        patch: "+\tram_start: 0x400A8000,\n"
      }

      File.mkdir_p!("boards/mk2")
      File.write!("boards/mk2/board.toml", "# temp")

      Application.put_env(:hatch, :kb_root, File.cwd!())

      ctx = %{
        session_id: "s_test",
        read_log: read_log,
        kb_root: File.cwd!()
      }

      try do
        # Should fail because the citation doesn't mention this address
        assert {:error, err} = Citations.check(proposal, ctx)
        assert err.code == :uncited_claim
        assert String.contains?(err.message, "0x400A8000")
      after
        File.rm!("boards/mk2/board.toml")
        File.rmdir!("boards/mk2")
        Application.delete_env(:hatch, :kb_root)
      end
    end
  end
end
