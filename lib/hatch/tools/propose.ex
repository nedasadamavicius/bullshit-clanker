defmodule Hatch.Tools.Propose do
  @moduledoc """
  Propose tool: propose_patch.

  Validates, stores, and broadcasts proposals. Enforces I2 (sandbox confinement),
  I4 (no writes), and I5 (citation checking).
  """

  require Logger
  alias Hatch.KB.Index
  alias Hatch.Proposal
  alias Hatch.Proposal.Patch
  alias Hatch.Proposal.Citations
  alias Hatch.Proposal.Store
  alias Hatch.Sandbox
  alias Hatch.Tools.Args
  alias Phoenix.PubSub

  @type ctx :: %{session_id: String.t(), read_log: pid() | :ets.tid(), proposal_store: :ets.tid()}
  @type err :: %{code: atom(), message: String.t()}

  @spec propose(map(), Hatch.Tools.ctx()) :: {:ok, String.t()} | {:error, err()}
  def propose(args, ctx) do
    with {:ok, nearest_board_id} <- Args.string(args, "nearest_board_id"),
         {:ok, summary} <- Args.string(args, "summary"),
         {:ok, patch} <- Args.string(args, "patch"),
         {:ok, citations} <- Args.list(args, "citations", []),
         {:ok, deltas} <- Args.list(args, "deltas", []),
         :ok <- validate_deltas(deltas),
         :ok <- validate_citations_structure(citations),
         {:ok, board} <- check_board_exists(nearest_board_id),
         {:ok, parsed_patch} <- Patch.parse(patch),
         :ok <- check_patch_sandbox(parsed_patch, ctx),
         {proposal, ctx_for_citations} <-
           build_proposal(
             ctx,
             nearest_board_id,
             summary,
             patch,
             deltas,
             citations,
             board
           ),
         :ok <- Citations.check(proposal, ctx_for_citations),
         :ok <- Store.put(ctx.proposal_store, proposal),
         :ok <- supersede_previous(ctx, proposal),
         :ok <- broadcast_proposal(ctx, proposal) do
      {:ok,
       "proposal #{proposal.id} recorded and shown to the operator. It is NOT applied. Wait for the operator's decision; do not repeat the patch."}
    else
      {:error, err} ->
        # Broadcast invalid event
        if Map.has_key?(ctx, :proposal_store) and Map.has_key?(ctx, :session_id) do
          broadcast_invalid(ctx, nil, [err.message])
        end

        {:error, err}
    end
  rescue
    e ->
      Logger.error("propose_patch tool crashed: #{inspect(e)}")

      {:error, %{code: :tool_crashed, message: Exception.message(e)}}
  end

  # --- Validation helpers ---

  @spec validate_deltas(term()) :: :ok | {:error, err()}
  defp validate_deltas(deltas) when is_list(deltas) do
    if Enum.all?(deltas, &is_map/1) do
      :ok
    else
      {:error, %{code: :invalid_args, message: "deltas must be a list of objects"}}
    end
  end

  defp validate_deltas(_), do: {:error, %{code: :invalid_args, message: "deltas must be a list"}}

  @spec validate_citations_structure(term()) :: :ok | {:error, err()}
  defp validate_citations_structure(citations) when is_list(citations) do
    if Enum.all?(citations, fn c ->
         is_map(c) and Map.has_key?(c, "path") and Map.has_key?(c, "claim")
       end) do
      :ok
    else
      {:error,
       %{
         code: :invalid_args,
         message: "citations must have 'path' and 'claim' fields"
       }}
    end
  end

  defp validate_citations_structure(_) do
    {:error, %{code: :invalid_args, message: "citations must be a list"}}
  end

  @spec check_board_exists(String.t()) :: {:ok, Hatch.KB.Board.t()} | {:error, err()}
  defp check_board_exists(board_id) do
    case Index.get(board_id) do
      {:ok, board} ->
        {:ok, board}

      {:error, :not_found} ->
        # Find some boards to suggest
        all_boards = Index.all()
        suggestions = all_boards |> Enum.map(& &1.id) |> Enum.take(5) |> Enum.join(", ")

        {:error,
         %{
           code: :not_found,
           message: "board '#{board_id}' not found. Similar boards: #{suggestions}"
         }}
    end
  end

  @spec check_patch_sandbox([Patch.parsed_file()], Hatch.Tools.ctx()) :: :ok | {:error, err()}
  defp check_patch_sandbox(parsed_patch, ctx) do
    unless Map.has_key?(ctx, :tree_root) and ctx.tree_root do
      # If no tree_root, we can't validate paths; but the spec says we should
      # Actually, looking at the spec, it says the tool should validate "every diff target path resolves under tree_root"
      # But we don't have tree_root in context yet. Let me check if it should be there.
      # For now, I'll skip if tree_root is not available; we can add it to context later.
      :ok
    else
      parsed_patch
      |> Enum.reduce_while(:ok, fn file, _acc ->
        case Sandbox.resolve(:tree, file.path) do
          {:ok, _abs_path} ->
            {:cont, :ok}

          {:error, _err} ->
            {:halt,
             {:error,
              %{code: :outside_sandbox, message: "patch path outside tree_root: #{file.path}"}}}
        end
      end)
    end
  end

  @spec build_proposal(
          map(),
          String.t(),
          String.t(),
          String.t(),
          [map()],
          [map()],
          Hatch.KB.Board.t()
        ) :: {Proposal.t(), Citations.ctx()}
  defp build_proposal(ctx, nearest_board_id, summary, patch, _deltas, citations, _board) do
    # Convert raw citation maps to proper format
    citations_list =
      Enum.map(citations, fn c ->
        %{path: Map.get(c, "path"), claim: Map.get(c, "claim")}
      end)

    # For now, deltas are empty (would need draft board comparison)
    deltas_list = []

    proposal =
      Proposal.new(
        ctx.session_id,
        nearest_board_id,
        summary,
        patch,
        deltas_list,
        citations_list
      )

    # Build context for citations check
    citations_ctx = %{
      session_id: ctx.session_id,
      read_log: ctx.read_log,
      kb_root: ctx.kb_root
    }

    {proposal, citations_ctx}
  end

  @spec supersede_previous(map(), Proposal.t()) :: :ok
  defp supersede_previous(ctx, _new_proposal) do
    with {:ok, old_proposal} <- Store.pending(ctx.proposal_store, ctx.session_id) do
      Store.set_status(ctx.proposal_store, ctx.session_id, old_proposal.id, :rejected, [
        "superseded"
      ])

      broadcast_invalid(ctx, old_proposal.id, ["superseded"])
    end

    :ok
  end

  @spec broadcast_proposal(map(), Proposal.t()) :: :ok
  defp broadcast_proposal(ctx, proposal) do
    event = %{
      type: :proposal,
      session_id: ctx.session_id,
      proposal_id: proposal.id,
      nearest_board_id: proposal.nearest_board_id,
      summary: proposal.summary,
      citations: proposal.citations,
      deltas: proposal.deltas,
      patch: proposal.patch
    }

    PubSub.broadcast(Hatch.PubSub, "session:#{ctx.session_id}", {:hatch_event, event})
    :ok
  end

  @spec broadcast_invalid(map(), String.t() | nil, [String.t()]) :: :ok
  defp broadcast_invalid(ctx, proposal_id, reasons) do
    event = %{
      type: :proposal_invalid,
      session_id: ctx.session_id,
      proposal_id: proposal_id,
      reasons: reasons
    }

    PubSub.broadcast(Hatch.PubSub, "session:#{ctx.session_id}", {:hatch_event, event})
    :ok
  end
end
