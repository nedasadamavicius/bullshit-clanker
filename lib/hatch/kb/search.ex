defmodule Hatch.KB.Search do
  @moduledoc """
  Ranking and search over boards. Structured: soc, uart, peripherals.
  """

  alias Hatch.KB.Board

  @type query :: %{
          optional(:soc) => String.t(),
          optional(:goarch) => String.t(),
          optional(:uart) => String.t(),
          optional(:peripherals) => [String.t()],
          optional(:text) => String.t(),
          optional(:exclude) => [String.t()],
          optional(:limit) => pos_integer()
        }

  @type t :: %__MODULE__{
          board: Board.t(),
          score: float(),
          soc_match: :exact | :family,
          why: [String.t()]
        }

  defstruct [:board, :score, :soc_match, :why]

  @spec search(query()) :: {:ok, [t()]} | {:error, %{code: atom(), message: String.t()}}
  def search(query) do
    candidates = Hatch.KB.Index.all()
    limit = Map.get(query, :limit, 5)
    exclude_set = MapSet.new(Map.get(query, :exclude, []))

    candidates
    |> Enum.filter(&(&1.id not in exclude_set))
    |> gate_by_soc(query)
    |> Enum.map(&score_candidate(&1, query))
    |> Enum.sort_by(&{-&1.score, &1.board.id})
    |> Enum.take(limit)
    |> then(&{:ok, &1})
  end

  @spec from_board(Board.t(), keyword()) :: {:ok, [t()]}
  def from_board(draft, opts \\ []) do
    limit = Keyword.get(opts, :limit, 5)
    exclude = Keyword.get(opts, :exclude, [])

    query =
      %{
        soc: if(Board.known?(draft.soc), do: draft.soc),
        uart: if(Board.known?(draft.uart), do: draft.uart),
        peripherals: if(Enum.any?(draft.peripherals), do: draft.peripherals),
        exclude: exclude,
        limit: limit
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    search(query)
  end

  # --- Private ---

  defp gate_by_soc(candidates, query) do
    case Map.get(query, :soc) do
      nil ->
        candidates

      soc_str ->
        soc_key = normalize_soc(soc_str)

        exact_matches = Enum.filter(candidates, &(&1.soc_key == soc_key))

        if not Enum.empty?(exact_matches) do
          exact_matches
        else
          Enum.filter(candidates, &soc_family_match?(&1.soc_key, soc_key))
        end
    end
  end

  defp soc_family_match?(:unknown, _query), do: false

  defp soc_family_match?(board_key, query_key) when is_binary(board_key) do
    case common_prefix_length(board_key, query_key) do
      len when len >= 4 -> true
      _ -> false
    end
  end

  defp common_prefix_length(a, b) do
    a_chars = String.graphemes(a)
    b_chars = String.graphemes(b)

    Enum.zip_with(a_chars, b_chars, fn x, y ->
      if x == y, do: 1, else: 0
    end)
    |> Enum.sum()
  end

  defp score_candidate(board, query) do
    soc_query = Map.get(query, :soc)
    soc_exact = if soc_query, do: board.soc_key == normalize_soc(soc_query), else: false

    soc_family =
      if soc_query && not soc_exact,
        do: soc_family_match?(board.soc_key, normalize_soc(soc_query)),
        else: false

    soc_match = if soc_exact, do: :exact, else: :family

    {score, why} = calculate_score(board, query, soc_exact, soc_family)

    %__MODULE__{
      board: board,
      score: score,
      soc_match: soc_match,
      why: why
    }
  end

  defp calculate_score(board, query, soc_exact, soc_family) do
    points = []

    # SoC match
    {points, why} =
      if soc_exact do
        {[10.0 | points], ["same soc #{board.soc}" | []]}
      else
        if soc_family do
          query_soc = Map.get(query, :soc)

          {[4.0 | points],
           ["different soc (#{board.soc} vs #{query_soc}) — verify every register" | []]}
        else
          {points, []}
        end
      end

    # UART match
    {points, why} =
      if Board.known?(board.uart) && query[:uart] do
        if String.downcase(board.uart) == String.downcase(query[:uart]) do
          {[3.0 | points], ["uart #{board.uart}" | why]}
        else
          {points, why}
        end
      else
        {points, why}
      end

    # Peripheral Jaccard
    {points, why} =
      if Enum.any?(board.peripherals) and Enum.any?(query[:peripherals] || []) do
        query_perips = query[:peripherals]
        board_set = MapSet.new(board.peripherals)
        query_set = MapSet.new(query_perips)
        intersection = MapSet.intersection(board_set, query_set)
        union = MapSet.union(board_set, query_set)

        jaccard =
          if MapSet.size(union) > 0 do
            MapSet.size(intersection) / MapSet.size(union)
          else
            0.0
          end

        points = [jaccard * 5.0 | points]

        why_entry =
          "#{MapSet.size(intersection)}/#{MapSet.size(query_set)} peripherals"

        {points, [why_entry | why]}
      else
        if not Enum.any?(board.peripherals) and Enum.any?(query[:peripherals] || []) do
          {points, ["peripherals unknown on kb" | why]}
        else
          if Enum.any?(board.peripherals) and not Enum.any?(query[:peripherals] || []) do
            {points, ["peripherals unknown on draft" | why]}
          else
            if not Enum.any?(board.peripherals) and not Enum.any?(query[:peripherals] || []) do
              {points, ["peripherals unknown on both" | why]}
            else
              {points, why}
            end
          end
        end
      end

    # Special peripherals: eth/phy, usb, flash variants
    {points, why} =
      (fn ->
         board_perips = MapSet.new(board.peripherals)
         query_perips = MapSet.new(query[:peripherals] || [])

         eth_phy =
           if (MapSet.member?(board_perips, "eth") or MapSet.member?(board_perips, "phy")) and
                (MapSet.member?(query_perips, "eth") or MapSet.member?(query_perips, "phy")) do
             0.5
           else
             0.0
           end

         usb =
           if MapSet.member?(board_perips, "usb") and MapSet.member?(query_perips, "usb") do
             0.5
           else
             0.0
           end

         flash =
           if (MapSet.member?(board_perips, "flash") or MapSet.member?(board_perips, "qspi") or
                 MapSet.member?(board_perips, "usdhc") or MapSet.member?(board_perips, "nand")) and
                (MapSet.member?(query_perips, "flash") or MapSet.member?(query_perips, "qspi") or
                   MapSet.member?(query_perips, "usdhc") or MapSet.member?(query_perips, "nand")) do
             0.5
           else
             0.0
           end

         special_score = Enum.sum([eth_phy, usb, flash])
         new_points = if special_score > 0, do: [special_score | points], else: points
         {new_points, why}
       end).()

    # goarch match
    {points, why} =
      if Board.known?(board.goarch) && query[:goarch] do
        if board.goarch == query[:goarch] do
          {[1.0 | points], ["goarch #{board.goarch}" | why]}
        else
          {points, why}
        end
      else
        {points, why}
      end

    # goarm match
    {points, why} =
      if Board.known?(board.goarm) && query[:goarm] do
        if board.goarm == query[:goarm] do
          {[0.5 | points], ["goarm #{board.goarm}" | why]}
        else
          {points, why}
        end
      else
        {points, why}
      end

    # tree exists
    {points, why} =
      if Board.known?(board.tree) do
        {[1.0 | points], ["has tree" | why]}
      else
        {points, why}
      end

    # ram_size match
    {points, why} =
      if Board.known?(board.ram_size) && query[:ram_size] do
        if board.ram_size == query[:ram_size] do
          {[1.0 | points], ["ram_size 0x#{Integer.to_string(board.ram_size, 16)}" | why]}
        else
          {points, why}
        end
      else
        {points, why}
      end

    # FTS/text match (if text filter is passed)
    {points, why} =
      if query[:text] do
        # Simple substring match for now
        text_lower = String.downcase(query[:text])
        board_text = Board.to_facts(board) |> String.downcase()

        if String.contains?(board_text, text_lower) do
          {[1.0 | points], ["text match" | why]}
        else
          {points, why}
        end
      else
        {points, why}
      end

    score = points |> Enum.sum() |> Float.round(1)

    # Sort why by descending points (approximate; group key contributions)
    why_sorted =
      why
      |> Enum.map(&why_to_points/1)
      |> Enum.sort_by(&{-elem(&1, 1), elem(&1, 0)})
      |> Enum.map(&elem(&1, 0))

    {score, why_sorted}
  end

  defp why_to_points(entry) do
    cond do
      String.starts_with?(entry, "same soc") -> {entry, 10.0}
      String.starts_with?(entry, "different soc") -> {entry, 4.0}
      String.starts_with?(entry, "uart") -> {entry, 3.0}
      String.ends_with?(entry, "peripherals") -> {entry, 2.5}
      String.starts_with?(entry, "goarch") -> {entry, 1.0}
      String.starts_with?(entry, "has tree") -> {entry, 1.0}
      String.starts_with?(entry, "ram_size") -> {entry, 1.0}
      String.starts_with?(entry, "text match") -> {entry, 1.0}
      String.starts_with?(entry, "goarm") -> {entry, 0.5}
      true -> {entry, 0.0}
    end
  end

  defp normalize_soc(soc) do
    soc
    |> String.downcase()
    |> String.replace(~r/[-_ ]/, "")
  end
end
