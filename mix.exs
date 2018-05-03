defmodule AmqpDirector.MixProject do
  use Mix.Project

  def project do
    [
      app: :amqp_director,
      version: "1.0.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_deps: :transitive,
                 flags: [:error_handling, :race_conditions, :underspecs]],
      docs: [extras: ["README.md"], main: "readme"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      applications: [:gproc, :lager, :amqp_client]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.16", only: :dev, runtime: false},
      {:dialyxir, "~> 0.5", only: :dev, runtime: false},
      {:amqp_client, "~> 3.7.4"},
      {:gproc, "~> 0.6.1"},
      {:lager, "~> 3.6", override: true}
    ]
  end

  defp package() do
    [
      files: ["lib", "src", "mix.exs", "rebar.config", "config", "README*", "readme*", "LICENSE*", "license*"],
      maintainers: ["Issuu"],
      organization: "issuu",
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/issuu/amqp_director"}
    ]
  end
end
