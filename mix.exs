defmodule AmqpDirector.MixProject do
  use Mix.Project

  def project do
    [
      app: :amqp_director,
      description: "A simplistic embeddable RPC Client/Server library for AMQP/RabbitMQ.",
      version: "1.2.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      dialyzer: [
        plt_add_deps: :transitive,
        flags: [:error_handling, :race_conditions, :underspecs]
      ],
      docs: [extras: ["README.md"], main: "readme"],
      source_url: "https://github.com/issuu/amqp_director"
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
      {:lager, "~> 3.5.1"}
    ]
  end

  defp package() do
    [
      files: ["lib", "src", "mix.exs", "rebar.config", "config", "README*", "LICENSE*"],
      maintainers: ["Issuu"],
      licenses: ["Apache 2.0"],
      links: %{"GitHub" => "https://github.com/issuu/amqp_director"}
    ]
  end
end
