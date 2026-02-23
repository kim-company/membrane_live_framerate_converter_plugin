defmodule Membrane.LiveFramerateConverter.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_live_framerate_converter_plugin,
      version: "1.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/kim-company/membrane_live_framerate_converter_plugin",
      homepage_url: "https://github.com/kim-company/membrane_live_framerate_converter_plugin",
      name: "Membrane Live Framerate Converter Plugin",
      description: description(),
      docs: docs(),
      package: package(),
      deps: deps()
    ]
  end

  defp description do
    """
    A Membrane filter that stabilizes raw video output to a target framerate by
    duplicating or dropping frames, with configurable stall handling.
    """
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: "https://github.com/kim-company/membrane_live_framerate_converter_plugin"
    ]
  end

  defp package do
    [
      maintainers: ["KIM Keep In Mind"],
      files: ~w(lib mix.exs README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/kim-company/membrane_live_framerate_converter_plugin"
      }
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:membrane_core, "~> 1.2"},
      {:membrane_raw_video_format, "~> 0.2"},
      {:membrane_realtimer_plugin, "~> 0.10", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
