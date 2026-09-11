defmodule Hatch.Permit do
  @moduledoc """
  Single-use write permit for applying patches (I4).

  A permit is minted only by Hatch.TUI on an explicit accept keypress,
  and consumed once by Hatch.Patch.Apply. Each permit is valid for 5 minutes
  and includes a patch hash to prevent stale applies.
  """

  @type t :: %__MODULE__{
          proposal_id: String.t(),
          session_id: String.t(),
          nonce: binary(),
          patch_hash: String.t(),
          issued_at: integer()
        }

  @derive Jason.Encoder
  defstruct [:proposal_id, :session_id, :nonce, :patch_hash, :issued_at]

  # 5 minutes
  @permit_ttl_ms 5 * 60 * 1000

  @ets_table_name :hatch_permit_spent

  @spec mint(String.t(), String.t(), String.t()) :: t()
  def mint(proposal_id, session_id, patch_hash) do
    nonce = :crypto.strong_rand_bytes(16)
    issued_at = System.monotonic_time(:millisecond)

    %__MODULE__{
      proposal_id: proposal_id,
      session_id: session_id,
      nonce: nonce,
      patch_hash: patch_hash,
      issued_at: issued_at
    }
  end

  @spec consume(t(), integer() | nil) :: :ok | {:error, atom()}
  def consume(permit, now_ms \\ nil) do
    now_ms = now_ms || System.monotonic_time(:millisecond)

    # Ensure the spent table exists
    ensure_table()

    # Check expiry
    if now_ms - permit.issued_at > @permit_ttl_ms do
      {:error, :expired}
    else
      # Check if already spent
      case :ets.lookup(@ets_table_name, permit.nonce) do
        [{_nonce, true}] ->
          {:error, :spent}

        [] ->
          # Mark as spent
          :ets.insert(@ets_table_name, {permit.nonce, true})
          :ok
      end
    end
  end

  defp ensure_table do
    unless :ets.whereis(@ets_table_name) != :undefined do
      :ets.new(@ets_table_name, [:set, :public, :named_table])
    end
  end
end
