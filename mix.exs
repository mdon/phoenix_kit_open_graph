defmodule PhoenixKitOg.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_og"

  def project do
    [
      app: :phoenix_kit_og,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "OpenGraph template + hierarchical assignment module for PhoenixKit",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitOg",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        "cmd mix hex.audit",
        "quality.ci"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. Export PHOENIX_KIT_PATH=
  # ../phoenix_kit for cross-repo work against a local checkout.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      pk_dep(:phoenix_kit, "~> 1.7"),
      {:phoenix_live_view, "~> 1.1"},
      {:ecto_sql, "~> 3.13"},
      # SVG → PNG rendering. Ships a precompiled NIF via rustler_precompiled
      # — no system binary needed in the common case. The parent app already
      # carries `:rustler` as an optional dep so the source-build fallback
      # works on bleeding-edge OTP NIF versions (see /www/app/mix.exs).
      {:resvg, "~> 0.5"},
      # `mdex_native` (transitive via phoenix_kit) needs rustler on hosts
      # where its precompiled NIF doesn't match the local NIF version.
      # Optional + `>= 0.0.0` so we don't pin a version that fights hex
      # deps; matches the parent app's declaration.
      {:rustler, ">= 0.0.0", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitOg",
      source_ref: "v#{@version}"
    ]
  end
end
