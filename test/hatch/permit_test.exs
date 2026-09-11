defmodule Hatch.PermitTest do
  use ExUnit.Case
  alias Hatch.Permit

  setup do
    # Clear the spent table
    if :ets.whereis(:hatch_permit_spent) != :undefined do
      :ets.delete(:hatch_permit_spent)
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
    now_ms = permit.issued_at + (5 * 60 * 1000) + 1000

    assert {:error, :expired} == Permit.consume(permit, now_ms)
  end

  test "consume succeeds just before 5 minute expiry" do
    permit = Permit.mint("p_test", "sess_test", "hash_test")
    # 5 minutes - 1 second
    now_ms = permit.issued_at + (5 * 60 * 1000) - 1000

    assert :ok == Permit.consume(permit, now_ms)
  end
end
