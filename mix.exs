defmodule AmqpDirector.MixProject do
  use Mix.Project

  def project do
    [
      app: :amqp_director,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [plt_add_deps: :transitive,
                 flags: [:error_handling, :race_conditions, :underspecs]]
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
      {:dialyxir, "~> 0.5", only: [:dev], runtime: false},
      {:amqp_client, "~> 3.7.4"},
      {:gproc, "~> 0.6.1"},
      {:lager, "~> 3.6", override: true}
    ]
  end
end
