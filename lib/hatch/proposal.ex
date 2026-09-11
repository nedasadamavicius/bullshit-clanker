defmodule Hatch.Proposal do
  @moduledoc """
  Proposal struct and ID generation.

  A proposal is the output of a bring-up turn: a patch + citation list,
  not a merged tree. It carries its validation state and requires human
  review and explicit keypress to apply.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          nearest_board_id: String.t(),
          summary: String.t(),
          deltas: [Hatch.KB.Delta.t()],
          citations: [%{path: String.t(), claim: String.t()}],
          patch: String.t(),
          status: :pending | :applied | :rejected | :invalid,
          invalid_reasons: [String.t()],
          created_at: DateTime.t()
        }

  @derive Jason.Encoder
  defstruct [
    :id,
    :session_id,
    :nearest_board_id,
    :summary,
    :deltas,
    :citations,
    :patch,
    :status,
    :invalid_reasons,
    :created_at
  ]

  @spec new(String.t(), String.t(), String.t(), String.t(), [Hatch.KB.Delta.t()], [
          %{path: String.t(), claim: String.t()}
        ]) :: t()
  def new(session_id, nearest_board_id, summary, patch, deltas, citations) do
    %__MODULE__{
      id: generate_id(),
      session_id: session_id,
      nearest_board_id: nearest_board_id,
      summary: summary,
      deltas: deltas,
      citations: citations,
      patch: patch,
      status: :pending,
      invalid_reasons: [],
      created_at: DateTime.utc_now()
    }
  end

  @spec generate_id() :: String.t()
  defp generate_id do
    "p_" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
  end
end
