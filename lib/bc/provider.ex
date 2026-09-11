defmodule BC.Provider do
  @moduledoc """
  OpenAI-compatible presets for xAI (Grok) and Anthropic (Claude).

  Still one HTTP client (`BC.Model.OpenAI`). No vendor SDK.
  """

  @presets %{
    "xai" => %{
      id: :xai,
      api_base: "https://api.x.ai/v1",
      model: "grok-4",
      key_env: "XAI_API_KEY"
    },
    "grok" => %{
      id: :xai,
      api_base: "https://api.x.ai/v1",
      model: "grok-4",
      key_env: "XAI_API_KEY"
    },
    "anthropic" => %{
      id: :anthropic,
      api_base: "https://api.anthropic.com/v1",
      model: "claude-sonnet-4-5",
      key_env: "ANTHROPIC_API_KEY"
    },
    "claude" => %{
      id: :anthropic,
      api_base: "https://api.anthropic.com/v1",
      model: "claude-sonnet-4-5",
      key_env: "ANTHROPIC_API_KEY"
    },
    "openai" => %{
      id: :openai,
      api_base: "https://api.openai.com/v1",
      model: "gpt-4o",
      key_env: "OPENAI_API_KEY"
    }
  }

  @type id :: :xai | :anthropic | :openai | :compat

  @spec resolve(map(), keyword()) ::
          {:ok,
           %{
             provider: id(),
             model: String.t(),
             ingest_model: String.t(),
             api_base: String.t(),
             api_key: String.t()
           }}
          | {:error, %{code: atom(), message: String.t()}}
  def resolve(env, opts \\ []) when is_map(env) do
    env = merge_secrets(env, opts)
    explicit = explicit_provider(env)
    provider = explicit || infer(env)
    preset = preset(provider)

    with {:ok, api_key} <- api_key(env, preset),
         {:ok, model} <- model(env, preset, provider != :compat),
         {:ok, api_base} <- api_base(env, preset) do
      ingest_model = Map.get(env, "BC_MODEL_INGEST", model)

      {:ok,
       %{
         provider: provider,
         model: model,
         ingest_model: ingest_model,
         api_base: api_base,
         api_key: api_key
       }}
    end
  end

  @spec has_api_key?(map() | nil) :: boolean()
  def has_api_key?(env \\ nil) do
    env = env || System.get_env()
    match?({:ok, _}, resolve(env))
  end

  @spec of(map() | struct()) :: id()
  def of(%{provider: p}) when p in [:xai, :anthropic, :openai, :compat], do: p

  def of(%{api_base: base}) when is_binary(base) do
    cond do
      String.contains?(base, "anthropic.com") -> :anthropic
      String.contains?(base, "api.x.ai") -> :xai
      String.contains?(base, "openai.com") -> :openai
      true -> :compat
    end
  end

  def of(_), do: :compat

  @spec headers(id() | String.t() | map() | struct() | nil) :: [{String.t(), String.t()}]
  def headers(provider_or_config) do
    case normalize(provider_or_config) do
      :anthropic -> [{"anthropic-version", "2023-06-01"}]
      _ -> []
    end
  end

  @spec anthropic?(id() | String.t() | map() | struct() | nil) :: boolean()
  def anthropic?(provider_or_config), do: normalize(provider_or_config) == :anthropic

  defp normalize(%{provider: _} = config), do: of(config)
  defp normalize(%{api_base: _} = config), do: of(config)
  defp normalize(:anthropic), do: :anthropic
  defp normalize("anthropic"), do: :anthropic
  defp normalize(:xai), do: :xai
  defp normalize(:openai), do: :openai
  defp normalize(:compat), do: :compat
  defp normalize(_), do: :compat

  defp explicit_provider(env) do
    case env |> Map.get("BC_PROVIDER", "") |> String.downcase() |> String.trim() do
      "" ->
        nil

      name ->
        case Map.get(@presets, name) do
          %{id: id} -> id
          nil -> :compat
        end
    end
  end

  defp infer(env) do
    base = env["BC_API_BASE"] || ""

    cond do
      String.contains?(base, "anthropic.com") ->
        :anthropic

      String.contains?(base, "api.x.ai") ->
        :xai

      String.contains?(base, "openai.com") ->
        :openai

      present?(env["ANTHROPIC_API_KEY"]) and not present?(env["BC_API_KEY"]) ->
        :anthropic

      present?(env["XAI_API_KEY"]) and not present?(env["BC_API_KEY"]) ->
        :xai

      present?(base) ->
        :compat

      true ->
        :anthropic
    end
  end

  defp merge_secrets(env, opts) do
    case secrets_source(opts) do
      :skip -> env
      path -> Map.merge(BC.Secrets.load(path), env)
    end
  end

  defp secrets_source(opts) do
    case Keyword.get(opts, :secrets_file, :auto) do
      false ->
        :skip

      path when is_binary(path) ->
        path

      :auto ->
        if mix_test?(), do: :skip, else: BC.Secrets.default_path()
    end
  end

  defp mix_test? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp preset(:xai), do: @presets["xai"]
  defp preset(:anthropic), do: @presets["anthropic"]
  defp preset(:openai), do: @presets["openai"]
  defp preset(:compat), do: %{id: :compat, api_base: nil, model: nil, key_env: nil}

  defp api_key(env, preset) do
    candidates =
      ["BC_API_KEY", preset[:key_env]]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case Enum.find_value(candidates, fn k ->
           val = env[k]
           if present?(val), do: val
         end) do
      nil ->
        names = Enum.join(candidates, " or ")

        {:error,
         %{
           code: :missing_env,
           message:
             "#{names} is not set. Copy config/secrets.env.example to config/secrets.env and paste the key."
         }}

      key ->
        {:ok, key}
    end
  end

  defp api_base(env, preset) do
    case env["BC_API_BASE"] || preset[:api_base] do
      nil ->
        {:error, %{code: :missing_env, message: "BC_API_BASE is not set"}}

      base ->
        {:ok, String.trim_trailing(base, "/")}
    end
  end

  defp model(env, preset, default_model?) do
    default = if default_model?, do: preset[:model]

    case env["BC_MODEL"] || default do
      nil ->
        {:error, %{code: :missing_env, message: "BC_MODEL is not set"}}

      model ->
        {:ok, model}
    end
  end

  defp present?(val) when is_binary(val), do: String.trim(val) != ""
  defp present?(_), do: false
end
