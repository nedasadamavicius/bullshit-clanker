defmodule Hatch.KB.Index do
  @moduledoc """
  KB index: sqlite + ETS, rebuild on change. Manages boards and FTS search.
  """

  use GenServer
  require Logger

  alias Hatch.KB.Board
  alias Hatch.KB.Loader

  @schema_version "1"

  @spec ensure_built() ::
          {:ok, %{boards: non_neg_integer(), rebuilt: boolean()}}
          | {:error, %{code: atom(), message: String.t()}}
  def ensure_built do
    GenServer.call(__MODULE__, :ensure_built)
  end

  @spec all() :: [Board.t()]
  def all do
    :ets.tab2list(:hatch_kb)
    |> Enum.map(&elem(&1, 1))
  end

  @spec get(String.t()) :: {:ok, Board.t()} | {:error, :not_found}
  def get(board_id) do
    case :ets.lookup(:hatch_kb, board_id) do
      [{^board_id, board}] -> {:ok, board}
      [] -> {:error, :not_found}
    end
  end

  @spec fts(String.t(), pos_integer()) :: [String.t()]
  def fts(query, limit) do
    GenServer.call(__MODULE__, {:fts, query, limit})
  end

  @spec reload() :: {:ok, map()}
  def reload do
    GenServer.call(__MODULE__, :reload)
  end

  @spec warnings() :: [map()]
  def warnings do
    GenServer.call(__MODULE__, :warnings)
  end

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    :ets.new(:hatch_kb, [:named_table, :protected, read_concurrency: true])

    state = %{
      kb_root: nil,
      db_path: nil,
      db_conn: nil,
      warnings: [],
      sqlite_warned: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:ensure_built, _from, state) do
    kb_root = get_kb_root(state)
    db_path = Path.join(kb_root, "index.sqlite")

    {:ok, boards, load_warnings} = Loader.load_all(kb_root)

    :ets.delete_all_objects(:hatch_kb)

    Enum.each(boards, fn board ->
      :ets.insert(:hatch_kb, {board.id, board})
    end)

    {rebuilt, db_conn, sqlite_warned, sqlite_warnings} =
      if state.sqlite_warned do
        {false, nil, true, []}
      else
        case ensure_db_built(db_path, boards) do
          {:ok, conn, rebuilt} ->
            {rebuilt, conn, false, []}

          {:error, :read_only} ->
            Logger.warning("KB directory is read-only; continuing with ETS only.")
            {false, nil, true, []}

          {:error, reason} ->
            Logger.warning(
              "Could not write index.sqlite: #{inspect(reason)}. Continuing with ETS only."
            )

            {false, nil, true, []}
        end
      end

    new_state = %{
      state
      | kb_root: kb_root,
        db_path: db_path,
        db_conn: db_conn,
        warnings: load_warnings ++ sqlite_warnings,
        sqlite_warned: sqlite_warned
    }

    {:reply, {:ok, %{boards: Enum.count(boards), rebuilt: rebuilt}}, new_state}
  end

  @impl true
  def handle_call(:reload, _from, state) do
    kb_root = get_kb_root(state)
    db_path = Path.join(kb_root, "index.sqlite")

    {:ok, boards, load_warnings} = Loader.load_all(kb_root)

    :ets.delete_all_objects(:hatch_kb)

    Enum.each(boards, fn board ->
      :ets.insert(:hatch_kb, {board.id, board})
    end)

    {rebuilt, db_conn, sqlite_warned, sqlite_warnings} =
      if state.sqlite_warned do
        {false, nil, true, []}
      else
        case ensure_db_built(db_path, boards) do
          {:ok, conn, rebuilt} ->
            {rebuilt, conn, false, []}

          {:error, :read_only} ->
            Logger.warning("KB directory is read-only; continuing with ETS only.")
            {false, nil, true, []}

          {:error, reason} ->
            Logger.warning(
              "Could not write index.sqlite: #{inspect(reason)}. Continuing with ETS only."
            )

            {false, nil, true, []}
        end
      end

    new_state = %{
      state
      | db_path: db_path,
        db_conn: db_conn,
        warnings: load_warnings ++ sqlite_warnings,
        sqlite_warned: sqlite_warned
    }

    {:reply, {:ok, %{boards: Enum.count(boards), rebuilt: rebuilt}}, new_state}
  end

  @impl true
  def handle_call(:warnings, _from, state) do
    {:reply, state.warnings, state}
  end

  @impl true
  def handle_call({:fts, query, limit}, _from, state) do
    results =
      if state.db_conn do
        fts_via_sqlite(state.db_conn, query, limit)
      else
        fts_via_ets(query, limit)
      end

    {:reply, results, state}
  end

  # --- Private ---

  defp get_kb_root(_state) do
    Hatch.Config.get().kb_root
  end

  defp ensure_db_built(db_path, boards) do
    File.mkdir_p!(Path.dirname(db_path))

    case Exqlite.start_link(database: db_path) do
      {:ok, conn} ->
        case needs_rebuild?(conn, boards) do
          true ->
            case rebuild_db(conn, boards) do
              :ok -> {:ok, conn, true}
              {:error, reason} -> {:error, reason}
            end

          false ->
            {:ok, conn, false}
        end

      {:error, %{message: message}} ->
        if String.contains?(message, "readonly") or String.contains?(message, "read-only") do
          {:error, :read_only}
        else
          {:error, message}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp needs_rebuild?(conn, boards) do
    case Exqlite.query(conn, "SELECT v FROM meta WHERE k = 'schema_version'", []) do
      {:ok, %Exqlite.Result{rows: [[version]]}} ->
        if version != @schema_version do
          true
        else
          check_board_shas(conn, boards)
        end

      _ ->
        true
    end
  end

  defp check_board_shas(conn, boards) do
    Enum.any?(boards, fn board ->
      board_sha = compute_board_sha(board)

      case Exqlite.query(conn, "SELECT sha256 FROM boards WHERE id = ?1", [board.id]) do
        {:ok, %Exqlite.Result{rows: [[stored_sha]]}} -> board_sha != stored_sha
        _ -> true
      end
    end)
  end

  defp rebuild_db(conn, boards) do
    try do
      Exqlite.query(conn, "BEGIN TRANSACTION", [])

      # Drop existing tables
      Exqlite.query(conn, "DROP TABLE IF EXISTS boards", [])
      Exqlite.query(conn, "DROP TABLE IF EXISTS peripherals", [])
      Exqlite.query(conn, "DROP TABLE IF EXISTS pinmux", [])
      Exqlite.query(conn, "DROP TABLE IF EXISTS boards_fts", [])
      Exqlite.query(conn, "DROP TABLE IF EXISTS meta", [])

      # Create schema
      Exqlite.query(
        conn,
        """
        CREATE TABLE boards (
          id TEXT PRIMARY KEY,
          source_path TEXT NOT NULL,
          soc TEXT,
          soc_key TEXT,
          goarch TEXT,
          goarm TEXT,
          ram_start INTEGER,
          ram_size INTEGER,
          uart TEXT,
          tamago_soc TEXT,
          tamago_board TEXT,
          tree TEXT,
          schematic TEXT,
          notes TEXT,
          sha256 TEXT NOT NULL,
          json TEXT NOT NULL
        )
        """,
        []
      )

      Exqlite.query(
        conn,
        """
        CREATE TABLE peripherals (
          board_id TEXT NOT NULL,
          name TEXT NOT NULL
        )
        """,
        []
      )

      Exqlite.query(
        conn,
        """
        CREATE TABLE pinmux (
          board_id TEXT NOT NULL,
          signal TEXT,
          pad TEXT,
          fn TEXT
        )
        """,
        []
      )

      Exqlite.query(
        conn,
        """
        CREATE VIRTUAL TABLE boards_fts USING fts5(
          id, soc, uart, peripherals, notes,
          content=''
        )
        """,
        []
      )

      Exqlite.query(
        conn,
        "CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT)",
        []
      )

      # Insert boards
      Enum.each(boards, fn board ->
        sha = compute_board_sha(board)
        json = Jason.encode!(board)

        soc_val = if Board.known?(board.soc), do: board.soc, else: nil
        soc_key = if Board.known?(board.soc_key), do: board.soc_key, else: nil
        goarch_val = if Board.known?(board.goarch), do: board.goarch, else: nil
        goarm_val = if Board.known?(board.goarm), do: board.goarm, else: nil
        ram_start_val = if is_integer(board.ram_start), do: board.ram_start, else: nil
        ram_size_val = if is_integer(board.ram_size), do: board.ram_size, else: nil
        uart_val = if Board.known?(board.uart), do: board.uart, else: nil
        tamago_soc_val = if Board.known?(board.tamago_soc), do: board.tamago_soc, else: nil

        tamago_board_val =
          if Board.known?(board.tamago_board), do: board.tamago_board, else: nil

        tree_val = if Board.known?(board.tree), do: board.tree, else: nil
        schematic_val = if Board.known?(board.schematic), do: board.schematic, else: nil
        notes_val = if Board.known?(board.notes), do: board.notes, else: nil

        Exqlite.query(
          conn,
          """
          INSERT INTO boards (
            id, source_path, soc, soc_key, goarch, goarm,
            ram_start, ram_size, uart, tamago_soc, tamago_board,
            tree, schematic, notes, sha256, json
          ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
          """,
          [
            board.id,
            board.source_path,
            soc_val,
            soc_key,
            goarch_val,
            goarm_val,
            ram_start_val,
            ram_size_val,
            uart_val,
            tamago_soc_val,
            tamago_board_val,
            tree_val,
            schematic_val,
            notes_val,
            sha,
            json
          ]
        )

        # Insert peripherals
        Enum.each(board.peripherals, fn periph ->
          Exqlite.query(
            conn,
            "INSERT INTO peripherals (board_id, name) VALUES (?1, ?2)",
            [board.id, periph]
          )
        end)

        # Insert pinmux
        Enum.each(board.pinmux, fn row ->
          Exqlite.query(
            conn,
            "INSERT INTO pinmux (board_id, signal, pad, fn) VALUES (?1, ?2, ?3, ?4)",
            [board.id, row.signal, row.pad, row.fn]
          )
        end)

        # Insert into FTS
        peripherals_str = Enum.join(board.peripherals, " ")

        Exqlite.query(
          conn,
          "INSERT INTO boards_fts (id, soc, uart, peripherals, notes) VALUES (?1, ?2, ?3, ?4, ?5)",
          [
            board.id,
            soc_val || "",
            uart_val || "",
            peripherals_str,
            notes_val || ""
          ]
        )
      end)

      # Insert meta
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      Exqlite.query(
        conn,
        "INSERT INTO meta (k, v) VALUES (?1, ?2)",
        ["schema_version", @schema_version]
      )

      Exqlite.query(
        conn,
        "INSERT INTO meta (k, v) VALUES (?1, ?2)",
        ["built_at", now]
      )

      Exqlite.query(conn, "COMMIT", [])

      :ok
    rescue
      e ->
        Exqlite.query(conn, "ROLLBACK", [])
        {:error, e}
    end
  end

  defp fts_via_sqlite(conn, query, limit) do
    case Exqlite.query(
           conn,
           """
           SELECT id FROM boards_fts
           WHERE boards_fts MATCH ?1
           LIMIT ?2
           """,
           [query, limit]
         ) do
      {:ok, %Exqlite.Result{rows: rows}} ->
        Enum.map(rows, &List.first/1)

      {:error, _} ->
        fts_via_ets(query, limit)
    end
  end

  defp fts_via_ets(query, limit) do
    query_lower = String.downcase(query)

    :hatch_kb
    |> :ets.tab2list()
    |> Enum.filter(fn {_id, board} ->
      board_text = Board.to_facts(board) |> String.downcase()
      String.contains?(board_text, query_lower)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(limit)
  end

  defp compute_board_sha(board) do
    board
    |> Map.take([
      :id,
      :source_path,
      :soc,
      :soc_key,
      :goarch,
      :goarm,
      :ram_start,
      :ram_size,
      :uart,
      :peripherals,
      :pinmux,
      :tamago_soc,
      :tamago_board,
      :schematic,
      :tree,
      :notes
    ])
    |> inspect(sort_maps: true)
    |> then(fn data -> :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) end)
  end
end
