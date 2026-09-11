defmodule BC.Build.Worker do
  use GenServer
  require Logger

  @moduledoc """
  GenServer that manages building the working tree with tamago-go.

  Runs at most one build at a time. A second concurrent build returns
  {:error, %{code: :busy, ...}}.

  Implements the builder behaviour for test seams via Application.get_env/3.
  """

  @behaviour BC.Build.Worker

  @type result :: %{
          build_id: String.t(),
          exit_status: integer(),
          timed_out: boolean(),
          duration_ms: non_neg_integer(),
          log: String.t()
        }

  @type err :: %{code: atom, message: String.t()}

  @callback build(String.t(), keyword()) :: {:ok, result()} | {:error, err()}

  @spec start_link(keyword()) :: {:ok, pid} | {:error, term}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  @spec build(session_id :: String.t(), opts :: [package: String.t(), timeout_ms: pos_integer()]) ::
          {:ok, result()} | {:error, err()}
  def build(session_id, opts) do
    builder = Application.get_env(:bc, :builder, __MODULE__)
    GenServer.call(builder, {:build, session_id, opts}, timeout_for_opts(opts) + 5_000)
  end

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config)
    Process.flag(:trap_exit, true)
    {:ok, %{current_build: nil, config: config}}
  end

  @impl true
  def handle_call({:build, session_id, opts}, _from, state) do
    case state.current_build do
      nil ->
        result = do_build(session_id, state.config, opts)
        {:reply, result, %{state | current_build: nil}}

      %{build_id: build_id} ->
        error = {:error, %{code: :busy, message: "a build is already running (#{build_id})"}}
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:EXIT, _port, _reason}, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.current_build do
      cleanup_port(state.current_build)
    end
  end

  defp do_build(session_id, config, opts) do
    case validate_build_args(opts) do
      {:error, _} = err ->
        err

      {:ok, package, timeout_ms} ->
        case find_tamago_go(config) do
          {:error, _} = err ->
            err

          {:ok, go_bin} ->
            run_build(session_id, go_bin, config, package, timeout_ms, opts)
        end
    end
  end

  defp validate_build_args(opts) do
    package = Keyword.get(opts, :package, "")
    timeout_ms = Keyword.get(opts, :timeout_ms, 120_000)

    cond do
      String.starts_with?(package, "-") ->
        {:error, %{code: :invalid_args, message: "package must not start with '-'"}}

      timeout_ms <= 0 ->
        {:error, %{code: :invalid_args, message: "timeout_ms must be positive"}}

      true ->
        {:ok, package, timeout_ms}
    end
  end

  defp find_tamago_go(config) do
    case System.find_executable(config.tamago_go) do
      nil ->
        {:error,
         %{
           code: :no_toolchain,
           message: "tamago-go not found on PATH (BC_TAMAGO_GO=#{config.tamago_go})"
         }}

      path ->
        {:ok, path}
    end
  end

  defp run_build(session_id, go_bin, config, package, timeout_ms, opts) do
    build_id = ("b_" <> :crypto.strong_rand_bytes(4)) |> Base.encode16(case: :lower)
    start_time = System.monotonic_time(:millisecond)
    goarch = arch_opt(opts, :goarch, "arm")
    goarm = arch_opt(opts, :goarm, "7")

    argv = [go_bin, "build", package]

    try do
      broadcast_event(session_id, :build_started, %{
        build_id: build_id,
        argv: argv
      })

      case spawn_port(go_bin, package, config, goarch, goarm) do
        {:ok, port} ->
          result = wait_for_build(session_id, port, timeout_ms, build_id, [])
          port_close(port)

          duration_ms = System.monotonic_time(:millisecond) - start_time

          broadcast_event(session_id, :build_finished, %{
            build_id: build_id,
            exit_status: result.exit_status,
            duration_ms: duration_ms,
            timed_out: result.timed_out
          })

          {:ok,
           %{
             build_id: build_id,
             exit_status: result.exit_status,
             timed_out: result.timed_out,
             duration_ms: duration_ms,
             log: truncate_for_tool(result.log_buffer)
           }}

        {:error, reason} ->
          {:error,
           %{code: :spawn_failed, message: "Failed to spawn build process: #{inspect(reason)}"}}
      end
    rescue
      e ->
        {:error, %{code: :internal_error, message: "Build error: #{inspect(e)}"}}
    end
  end

  defp arch_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      val when is_binary(val) and val != "" -> val
      _ -> default
    end
  end

  defp spawn_port(go_bin, package, config, goarch, goarm) do
    tree_root = config.tree_root || ""

    args = ["build", package]

    env =
      (System.get_env() || %{})
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      |> Enum.reject(fn {k, _} -> k in [~c"GOOS", ~c"GOARCH", ~c"GOARM", ~c"CGO_ENABLED"] end)
      |> then(fn e ->
        e ++
          [
            {~c"GOOS", ~c"tamago"},
            {~c"GOARCH", String.to_charlist(goarch)},
            {~c"GOARM", String.to_charlist(goarm)},
            {~c"CGO_ENABLED", ~c"0"}
          ]
      end)

    opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      :hide,
      args: args,
      cd: if(tree_root != "", do: tree_root, else: false),
      env: env
    ]

    try do
      port = Port.open({:spawn_executable, String.to_charlist(go_bin)}, opts)
      {:ok, port}
    rescue
      _e -> {:error, "Failed to open port"}
    end
  catch
    :error, reason -> {:error, reason}
  end

  defp wait_for_build(session_id, port, timeout_ms, build_id, buffer) do
    receive do
      {^port, {:data, chunk}} ->
        broadcast_event(session_id, :build_log, %{build_id: build_id, chunk: chunk})
        new_buffer = [chunk | buffer]
        wait_for_build(session_id, port, timeout_ms, build_id, new_buffer)

      {^port, {:exit_status, status}} ->
        log_buffer =
          buffer
          |> Enum.reverse()
          |> Enum.join("")
          |> truncate_buffer()

        %{exit_status: status, timed_out: false, log_buffer: log_buffer}
    after
      timeout_ms ->
        handle_timeout(session_id, port, build_id)
    end
  end

  defp handle_timeout(_session_id, port, _build_id) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        send_signal(pid, :term)
        Process.sleep(2_000)
        send_signal(pid, :kill)

      _ ->
        :ok
    end

    port_close(port)

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      1_000 -> :ok
    end

    %{exit_status: 124, timed_out: true, log_buffer: ""}
  end

  # Port.close/1 closes the pipe but leaves the child process running.
  # We must send TERM then KILL to reap the entire go build process tree.
  defp send_signal(pid, signal) when signal in [:term, :kill] do
    signum = if signal == :term, do: 15, else: 9

    try do
      System.cmd("kill", ["-#{signum}", Integer.to_string(pid)])
    rescue
      _e -> :ok
    catch
      _ -> :ok
    end
  end

  defp port_close(port) do
    try do
      Port.close(port)
    rescue
      _e -> :ok
    catch
      _ -> :ok
    end
  end

  defp cleanup_port(%{port: port}) do
    port_close(port)
  end

  defp cleanup_port(_), do: :ok

  defp broadcast_event(session_id, type, fields) do
    event = Map.put(fields, :type, type) |> Map.put(:session_id, session_id)

    try do
      Phoenix.PubSub.broadcast(
        BC.PubSub,
        "session:#{session_id}",
        {:bc_event, event}
      )
    rescue
      _e -> :ok
    catch
      _ -> :ok
    end
  end

  defp truncate_buffer(log_str) do
    size_bytes = byte_size(log_str)
    max_total = 1_048_576
    first_keep = 65_536
    last_keep = 524_288

    if size_bytes <= max_total do
      log_str
    else
      first_part = String.slice(log_str, 0, first_keep)
      last_part = String.slice(log_str, (size_bytes - last_keep)..-1)
      elided_count = size_bytes - first_keep - last_keep
      first_part <> "\n... (#{elided_count} bytes elided) ...\n" <> last_part
    end
  end

  defp truncate_for_tool(log_str) do
    size_bytes = byte_size(log_str)

    if size_bytes <= 32_768 do
      log_str
    else
      String.slice(log_str, (size_bytes - 32_768)..-1)
    end
  end

  defp timeout_for_opts(opts) do
    Keyword.get(opts, :timeout_ms, 120_000)
  end
end
