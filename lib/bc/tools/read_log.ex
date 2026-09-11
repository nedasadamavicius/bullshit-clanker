defmodule BC.Tools.ReadLog do
  @moduledoc """
  ETS-based read log for citation checking (invariant I5).

  Tracks {path, tool, at} for every successful kb.read and every KB path
  returned by kb.search.
  """

  @spec new() :: :ets.tid()
  def new do
    :ets.new(:read_log, [:set, :public, {:keypos, 1}])
  end

  @spec log(pid() | :ets.tid(), String.t(), String.t()) :: :ok
  def log(tid, path, tool) do
    :ets.insert(tid, {path, tool, System.monotonic_time(:millisecond)})
    :ok
  end

  @spec read?(pid() | :ets.tid(), String.t()) :: boolean()
  def read?(tid, path) do
    :ets.member(tid, path)
  end
end
