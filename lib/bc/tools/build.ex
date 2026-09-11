defmodule BC.Tools.Build do
  @moduledoc """
  tamago.build tool - delegates to BC.Build.Worker (spec 010).
  """

  alias BC.Tools.Args

  @spec build(map(), BC.Tools.ctx()) ::
          {:ok, String.t()} | {:error, %{code: atom(), message: String.t()}}
  def build(args, ctx) do
    with {:ok, package} <- Args.string(args, "package", "./..."),
         :ok <- validate_package(package) do
      builder = Application.get_env(:bc, :builder, BC.Build.Worker)

      timeout_ms = BC.Config.get().build_timeout_ms

      case builder.build(ctx.session_id,
             package: package,
             timeout_ms: timeout_ms,
             goarch: arch_from_ctx(ctx, :goarch, "arm"),
             goarm: arch_from_ctx(ctx, :goarm, "7")
           ) do
        {:ok, result} ->
          output = %{
            "exit_status" => result.exit_status,
            "timed_out" => result.timed_out,
            "log" => result.log
          }

          {:ok, Jason.encode!(output)}

        {:error, err} ->
          {:error, err}
      end
    else
      {:error, msg} ->
        {:error, %{code: :invalid_args, message: msg}}
    end
  end

  # --- Helpers ---

  defp arch_from_ctx(ctx, field, default) do
    case ctx[:draft] do
      %{^field => val} when is_binary(val) -> val
      _ -> default
    end
  end

  defp validate_package(package) do
    cond do
      String.starts_with?(package, "-") ->
        {:error, "package must not start with '-'"}

      Regex.match?(~r{^[A-Za-z0-9._/-]+$}, package) ->
        :ok

      true ->
        {:error, "package must match ^[A-Za-z0-9._/-]+$"}
    end
  end
end
