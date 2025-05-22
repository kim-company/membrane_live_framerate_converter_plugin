defmodule Membrane.LiveFramerateConverter.MixProject do
  use Mix.Project

  def project do
    [
      app: :membrane_live_framerate_converter_plugin,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
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
      {:membrane_core, "~> 0.12"},
      {:membrane_raw_video_format, "~> 0.2"},
      {:membrane_live_filter_plugin,
       github: "kim-company/membrane_live_filter_plugin", only: :test},
      {:kim_q, github: "kim-company/kim_q"},
      {:jason, "~> 1.4.0", only: :test}
    ]
  end
end
