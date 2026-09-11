defmodule Hatch.Config do
  @derive {Inspect, except: [:api_key]}
  defstruct [
    :kb_root,
    :tree_root,
    :model,
    :ingest_model,
    :build_model,
    :api_base,
    :api_key,
    :tamago_go,
    :build_timeout_ms
  ]

  @type t :: %__MODULE__{
          kb_root: Path.t(),
          tree_root: Path.t() | nil,
          model: String.t(),
          ingest_model: String.t(),
          build_model: String.t() | nil,
          api_base: String.t(),
          api_key: String.t(),
          tamago_go: String.t(),
          build_timeout_ms: pos_integer()
        }

  @spec from_argv([String.t()]) ::
          {:ok, t()} | {:error, %{code: atom, message: String.t()}} | {:halt, pos_integer, atom}
  def from_argv(argv) do
    case parse_argv(argv) do
      {:halt, code, reason} ->
        {:halt, code, reason}

      {:ok, parsed} ->
        case load_env(parsed) do
          {:ok, env} -> {:ok, env}
          error -> error
        end

      error ->
        error
    end
  end

  @spec from_env(map(), keyword()) :: {:ok, t()} | {:error, %{code: atom, message: String.t()}}
  def from_env(env_map, opts \\ []) do
    parsed = Keyword.take(opts, [:kb, :tree])
    load_env({parsed, env_map})
  end

  @spec put(t()) :: :ok
  def put(config) do
    :persistent_term.put({:hatch, :config}, config)
  end

  @spec get() :: t()
  def get do
    :persistent_term.get({:hatch, :config})
  end

  defp parse_argv(argv) do
    case parse_argv_impl(argv, []) do
      {:ok, parsed} -> {:ok, {parsed, System.get_env()}}
      error -> error
    end
  end

  defp parse_argv_impl([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_argv_impl(["--help" | _], _acc) do
    {:halt, 0, :help}
  end

  defp parse_argv_impl(["--version" | _], _acc) do
    {:halt, 0, :version}
  end

  defp parse_argv_impl(["--kb", path | rest], acc) do
    parse_argv_impl(rest, [{:kb, path} | acc])
  end

  defp parse_argv_impl(["--tree", path | rest], acc) do
    parse_argv_impl(rest, [{:tree, path} | acc])
  end

  defp parse_argv_impl([flag | _], _acc) when is_binary(flag) do
    if String.starts_with?(flag, "--") do
      {:error, %{code: :unknown_flag, message: "Unknown flag: #{flag}"}}
    else
      {:error, %{code: :invalid_args, message: "Unexpected argument: #{flag}"}}
    end
  end

  defp parse_argv_impl([arg | _], _acc) do
    {:error, %{code: :invalid_args, message: "Unexpected argument: #{arg}"}}
  end

  defp load_env({argv_opts, env_map}) do
    kb = Keyword.get(argv_opts, :kb)
    tree = Keyword.get(argv_opts, :tree)

    with :ok <- validate_kb(kb),
         :ok <- validate_tree(tree),
         {:ok, model} <- get_env_required(env_map, "HATCH_MODEL"),
         {:ok, api_base} <- get_env_required(env_map, "HATCH_API_BASE"),
         {:ok, api_key} <- get_env_required(env_map, "HATCH_API_KEY") do
      ingest_model = Map.get(env_map, "HATCH_MODEL_INGEST", model)
      build_model = Map.get(env_map, "HATCH_MODEL_BUILD")
      tamago_go = Map.get(env_map, "HATCH_TAMAGO_GO", "tamago-go")

      build_timeout_ms =
        case Map.get(env_map, "HATCH_BUILD_TIMEOUT_MS", "120000") do
          val when is_binary(val) ->
            case Integer.parse(val) do
              {n, ""} when n > 0 -> n
              _ -> 120_000
            end

          _ ->
            120_000
        end

      api_base_normalized = String.trim_trailing(api_base, "/")

      {:ok,
       %__MODULE__{
         kb_root: Path.expand(kb),
         tree_root: if(tree, do: Path.expand(tree)),
         model: model,
         ingest_model: ingest_model,
         build_model: build_model,
         api_base: api_base_normalized,
         api_key: api_key,
         tamago_go: tamago_go,
         build_timeout_ms: build_timeout_ms
       }}
    end
  end

  defp validate_kb(nil) do
    {:error, %{code: :missing_kb, message: "KB path is required. Use --kb PATH"}}
  end

  defp validate_kb(kb_path) do
    expanded = Path.expand(kb_path)

    unless File.exists?(expanded) && File.dir?(expanded) do
      {:error, %{code: :bad_kb, message: "KB path does not exist: #{kb_path}"}}
    else
      validate_kb_boards(expanded, kb_path)
    end
  end

  defp validate_kb_boards(expanded, kb_path) do
    boards_path = Path.join(expanded, "boards")

    unless File.exists?(boards_path) && File.dir?(boards_path) do
      {:error, %{code: :bad_kb, message: "KB path must contain a 'boards' directory: #{kb_path}"}}
    else
      :ok
    end
  end

  defp validate_tree(nil), do: :ok

  defp validate_tree(tree_path) do
    expanded = Path.expand(tree_path)

    if File.exists?(expanded) && File.dir?(expanded) do
      :ok
    else
      {:error, %{code: :bad_tree, message: "Tree path does not exist: #{tree_path}"}}
    end
  end

  defp get_env_required(env_map, key) do
    case Map.get(env_map, key) do
      nil ->
        {:error, %{code: :missing_env, message: "#{key} is not set"}}

      val ->
        {:ok, val}
    end
  end
end
