# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesMCP.MixProject do
  use Mix.Project

  @version "VERSION" |> File.read!() |> String.trim()
  @description "MCP server that lets AI assistants work with Nerves devices over serial or SSH"
  @source_url "https://github.com/nerves-project/nerves_mcp"

  def project do
    [
      app: :nerves_mcp,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "NervesMCP",
      description: @description,
      source_url: @source_url,
      docs: docs(),
      package: package(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      escript: escript()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {NervesMCP.Application, []}
    ]
  end

  def docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md", "CHANGELOG.md"],
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  def package do
    [
      name: :nerves_mcp,
      files: [
        "lib",
        "LICENSES",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "LICENSE.md",
        "CHANGELOG.md",
        "REUSE.toml",
        "VERSION"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "Changelog" => "https://hexdocs.pm/nerves_mcp/changelog.html",
        "GitHub" => @source_url,
        "REUSE Compliance" =>
          "https://api.reuse.software/info/github.com/nerves-project/nerves_mcp"
      }
    ]
  end

  def aliases do
    [
      check: [
        "hex.audit",
        "compile --warnings-as-errors --force",
        "format --check-formatted",
        "credo",
        "deps.unlock --check-unused",
        "spellweaver.check",
        "dialyzer"
      ]
    ]
  end

  def escript do
    [main_module: NervesMCP.CLI]
  end

  def dialyzer do
    [
      plt_add_apps: [:mix],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:emcp, "~> 0.3"},
      {:bandit, "~> 1.0"},
      {:circuits_uart, "~> 1.0"},
      {:circular_buffer, "~> 0.4 or ~> 1.0"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:ex_doc, "~> 0.31", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:spellweaver, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end
end
