defmodule BC.Tools.Args do
  @moduledoc """
  Hand-rolled argument validator for tool calls.
  """

  @spec string(map(), atom()) :: {:ok, String.t()} | {:error, String.t()}
  def string(args, key) do
    case Map.get(args, key) do
      nil ->
        {:error, "#{key} is required"}

      val when is_binary(val) ->
        {:ok, val}

      _ ->
        {:error, "#{key} must be a string"}
    end
  end

  @spec string(map(), atom(), term()) :: {:ok, String.t() | term()} | {:error, String.t()}
  def string(args, key, default) do
    case Map.get(args, key, default) do
      val when is_binary(val) ->
        {:ok, val}

      val ->
        if val == default do
          {:ok, val}
        else
          {:error, "#{key} must be a string"}
        end
    end
  end

  @spec integer(map(), atom(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def integer(args, key, default) do
    case Map.get(args, key, default) do
      val when is_integer(val) ->
        {:ok, val}

      val ->
        if val == default do
          {:ok, val}
        else
          {:error, "#{key} must be an integer"}
        end
    end
  end

  @spec integer_range(map(), atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def integer_range(args, key, min, max, default) do
    case integer(args, key, default) do
      {:error, _} = err ->
        err

      {:ok, val} ->
        if val >= min and val <= max do
          {:ok, val}
        else
          {:error, "#{key} must be between #{min} and #{max}"}
        end
    end
  end

  @spec string_list(map(), atom()) :: {:ok, [String.t()]} | {:error, String.t()}
  def string_list(args, key) do
    case Map.get(args, key) do
      nil ->
        {:error, "#{key} is required"}

      val when is_list(val) ->
        if Enum.all?(val, &is_binary/1) do
          {:ok, val}
        else
          {:error, "#{key} must be a list of strings"}
        end

      _ ->
        {:error, "#{key} must be a list of strings"}
    end
  end

  @spec string_list(map(), atom(), [String.t()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def string_list(args, key, default) do
    case Map.get(args, key, default) do
      val when is_list(val) ->
        if Enum.all?(val, &is_binary/1) do
          {:ok, val}
        else
          {:error, "#{key} must be a list of strings"}
        end

      val ->
        if val == default do
          {:ok, val}
        else
          {:error, "#{key} must be a list of strings"}
        end
    end
  end

  @spec pattern(String.t(), Regex.t()) :: {:ok, String.t()} | {:error, String.t()}
  def pattern(val, regex) do
    if Regex.match?(regex, val) do
      {:ok, val}
    else
      {:error, "value does not match required pattern"}
    end
  end

  @spec no_leading_dash(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def no_leading_dash(val) do
    if String.starts_with?(val, "-") do
      {:error, "must not start with '-'"}
    else
      {:ok, val}
    end
  end

  @spec list(map(), atom(), [term()]) :: {:ok, [term()]} | {:error, String.t()}
  def list(args, key, default) do
    case Map.get(args, key, default) do
      val when is_list(val) ->
        {:ok, val}

      val ->
        if val == default do
          {:ok, val}
        else
          {:error, "#{key} must be a list"}
        end
    end
  end

  @spec at_least_one([{atom(), term()}]) :: :ok | {:error, String.t()}
  def at_least_one(checks) do
    if Enum.any?(checks, fn {_k, v} -> v != nil end) do
      :ok
    else
      required = Enum.map(checks, fn {k, _} -> k end) |> Enum.join(", ")
      {:error, "at least one of #{required} is required"}
    end
  end
end
