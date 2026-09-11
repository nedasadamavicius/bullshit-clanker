defmodule BC.PermitTest do
  use ExUnit.Case
  alias BC.Permit

  setup do
    # Clear the spent table
    if :ets.whereis(:bc_permit_spent) != :undefined do
      :ets.delete(:bc_permit_spent)
    end

    :ok
  end

  test "mints a permit with proposal_id, session_id, and patch_hash" do
    permit = Permit.mint("p_abc123", "sess_xyz", "hash_001")

    assert permit.proposal_id == "p_abc123"
    assert permit.session_id == "sess_xyz"
    assert permit.patch_hash == "hash_001"
    assert is_binary(permit.nonce)
    assert is_integer(permit.issued_at)
  end

  test "consume succeeds for a valid, fresh permit" do
    permit = Permit.mint("p_test", "sess_test", "hash_test")
    now_ms = permit.issued_at + 1000

    assert :ok == Permit.consume(permit, now_ms)
  end

  test "consume fails on second use (spent)" do
    permit = Permit.mint("p_test", "sess_test", "hash_test")
    now_ms = permit.issued_at + 1000

    assert :ok == Permit.consume(permit, now_ms)
    assert {:error, :spent} == Permit.consume(permit, now_ms)
  end

  test "consume fails after 5 minutes (expired)" do
    permit = Permit.mint("p_test", "sess_test", "hash_test")
    # 5 minutes + 1 second
    now_ms = permit.issued_at + 5 * 60 * 1000 + 1000

    assert {:error, :expired} == Permit.consume(permit, now_ms)
  end

  test "consume succeeds just before 5 minute expiry" do
    permit = Permit.mint("p_test", "sess_test", "hash_test")
    # 5 minutes - 1 second
    now_ms = permit.issued_at + 5 * 60 * 1000 - 1000

    assert :ok == Permit.consume(permit, now_ms)
  end

  test "Permit.mint has exactly one production call site in BC.TUI" do
    # mix bc.accept / BC.Acceptance is the operator for spec 013.
    # Excluded from this 009 grep by filename (stated in both specs' comments).
    files =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(fn path ->
        String.ends_with?(path, "mix/tasks/bc.accept.ex") or
          String.ends_with?(path, "bc/acceptance.ex")
      end)

    hits =
      Enum.flat_map(files, fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> line =~ ~r/Permit\.mint\(/ end)
        |> Enum.map(fn {_line, n} -> {path, n} end)
      end)

    assert length(hits) == 1
    [{path, _n}] = hits
    assert path == "lib/bc/tui/model.ex"
  end
end
