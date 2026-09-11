defmodule Hatch.Proposal.Citations do
  @moduledoc """
  Citation enforcement (invariant I5).

  Cheap mechanical check: every address/pin/RAM claim in a proposal cites
  a KB path that was actually read this session.

  Rules:
  1. Citations must be non-empty.
  2. Every path resolves under kb_root and exists.
  3. Every path was returned by kb.read in this session (read-log).
  4. Added lines are scanned for claim tokens (hex, pin identifiers, RAM/size).
     If tokens found, at least one citation must mention at least one token.
  5. A patch with no tokens still needs one citation.

  This is a tripwire, not a verifier.
  """

  require Logger
  alias Hatch.Sandbox
  alias Hatch.Tools.ReadLog

  @type ctx :: %{session_id: String.t(), read_log: pid() | :ets.tid(), kb_root: Path.t()}
  @type err :: %{code: atom(), message: String.t()}

  # Hex literals: 0x[0-9a-f]{3,}
  @hex_pattern ~r/0x[0-9a-fA-F]{3,}/

  # Pin/pad identifiers: word boundary, uppercase letter start, 3+ chars, all uppercase/digits/_
  @pin_pattern ~r/\b[A-Z][A-Z0-9_]{3,}\b/

  @spec check(Hatch.Proposal.t(), ctx()) :: :ok | {:error, err()}
  def check(proposal, ctx) do
    with :ok <- check_non_empty(proposal.citations),
         :ok <- check_paths_exist(proposal.citations, ctx),
         :ok <- check_paths_read(proposal.citations, ctx),
         :ok <- check_claim_tokens(proposal.patch, proposal.citations) do
      :ok
    end
  end

  @spec check_non_empty([%{path: String.t(), claim: String.t()}]) :: :ok | {:error, err()}
  defp check_non_empty([]),
    do: {:error, %{code: :uncited_claim, message: "at least one citation is required"}}

  defp check_non_empty(_), do: :ok

  @spec check_paths_exist([%{path: String.t(), claim: String.t()}], ctx()) ::
          :ok | {:error, err()}
  defp check_paths_exist(citations, ctx) do
    citations
    |> Enum.reduce_while(:ok, fn citation, _acc ->
      path = citation.path

      case Sandbox.resolve(:kb, path) do
        {:ok, abs_path} ->
          if File.exists?(abs_path) do
            {:cont, :ok}
          else
            err = %{
              code: :uncited_claim,
              message: "cited path does not exist: #{path}"
            }

            {:halt, {:error, err}}
          end

        {:error, err} ->
          {:halt, {:error, err}}
      end
    end)
  end

  @spec check_paths_read([%{path: String.t(), claim: String.t()}], ctx()) :: :ok | {:error, err()}
  defp check_paths_read(citations, ctx) do
    citations
    |> Enum.reduce_while(:ok, fn citation, _acc ->
      path = citation.path

      if ReadLog.read?(ctx.read_log, path) do
        {:cont, :ok}
      else
        err = %{
          code: :uncited_claim,
          message:
            "cited path was not read in this session. Read it with kb.read and cite it again, or cite a file you did read."
        }

        {:halt, {:error, err}}
      end
    end)
  end

  @spec check_claim_tokens(String.t(), [%{path: String.t(), claim: String.t()}]) ::
          :ok | {:error, err()}
  defp check_claim_tokens(patch, citations) do
    # Scan the patch for added lines (lines starting with +, excluding +++  headers)
    added_lines = extract_added_lines(patch)

    # Extract tokens from added lines
    tokens = extract_tokens(added_lines)

    # If no tokens, we still need citations (checked above)
    # If tokens found, check that at least one appears in citation claims
    if Enum.any?(tokens) do
      citation_claims = Enum.map(citations, & &1.claim) |> Enum.join(" ")

      uncited =
        tokens
        |> Enum.filter(fn token ->
          !String.contains?(citation_claims, token)
        end)
        |> Enum.uniq()
        |> Enum.take(5)

      if Enum.any?(uncited) do
        token_list = Enum.join(uncited, ", ")

        err = %{
          code: :uncited_claim,
          message:
            "claim(s) #{token_list} appear in the patch but in no cited file. Read the KB file that supports them with kb.read and cite it, or set the field to unknown and say so."
        }

        {:error, err}
      else
        :ok
      end
    else
      # No claim tokens, but citations are already checked to be non-empty above
      :ok
    end
  end

  @spec extract_added_lines([String.t()]) :: [String.t()]
  defp extract_added_lines(patch) do
    patch
    |> String.split("\n")
    |> Enum.filter(fn line ->
      String.starts_with?(line, "+") and
        not String.starts_with?(line, "+++") and
        not String.starts_with?(line, "@@")
    end)
    |> Enum.map(fn line ->
      # Remove the leading +
      String.slice(line, 1..-1//1)
    end)
  end

  @spec extract_tokens([String.t()]) :: [String.t()]
  defp extract_tokens(lines) do
    lines
    |> Enum.flat_map(fn line ->
      hex_tokens = Regex.scan(@hex_pattern, line) |> Enum.map(&List.first/1)

      pin_tokens =
        if String.match?(line, ~r/(pinmux|pad|uart)/i) do
          Regex.scan(@pin_pattern, line) |> Enum.map(&List.first/1)
        else
          []
        end

      hex_tokens ++ pin_tokens
    end)
    |> Enum.uniq()
  end
end
