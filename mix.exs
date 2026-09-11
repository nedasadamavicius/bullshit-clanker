defmodule Hatch.MixProject do
  use Mix.Project

  def project do
    [
      app: :hatch,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Hatch.CLI, name: "hatch"],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Hatch.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:toml, "~> 0.7"},
      {:exqlite, "~> 0.23"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:phoenix_pubsub, "~> 2.1"}
      # {:ratatouille, "~> 0.5"}  # Disabled due to ex_termbox native build issues
    ]
  end
end
