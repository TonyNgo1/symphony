defmodule Mix.Tasks.Github.Plan do
  use Mix.Task
  alias SymphonyElixir.GitHub.Plan
  @shortdoc "Validate a JSON task graph and generate Backlog issue bodies (offline)"
  @moduledoc "Usage: mix github.plan plan.json [--output validated-plan.json]. No scheduler or GitHub writes."

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [output: :string])
    if invalid != [] or length(argv) != 1, do: Mix.raise(@moduledoc)
    Mix.Task.run("compile")
    [path] = argv

    with {:ok, contents} <- File.read(path),
         {:ok, plan} <- Jason.decode(contents),
         {:ok, bundle} <- Plan.compile(plan) do
      output = Jason.encode!(bundle, pretty: true) <> "\n"
      if opts[:output], do: File.write!(opts[:output], output), else: Mix.shell().info(output)
    else
      error -> Mix.raise("Plan validation failed: #{inspect(error)}")
    end
  end
end
