defmodule Mix.Tasks.Github.Handoff do
  use Mix.Task
  alias SymphonyElixir.{Config, WorkerRecovery, Workflow, WorkflowStore}
  alias SymphonyElixir.Tracker.Issue
  @shortdoc "Read a local issue's durable worker task IDs and checkpoints (offline)"
  @moduledoc "Usage: mix github.handoff GH-123 [--workflow WORKFLOW.md]. No scheduler or GitHub writes."

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: [workflow: :string])
    unless invalid == [] and match?([_], argv), do: Mix.raise(@moduledoc)
    [identifier] = argv
    unless Regex.match?(~r/^GH-[1-9][0-9]*$/, identifier), do: Mix.raise(@moduledoc)
    Mix.Task.run("compile")
    if opts[:workflow], do: Workflow.set_workflow_file_path(opts[:workflow])
    :ok = WorkflowStore.force_reload()

    issue = %Issue{
      id: String.replace_prefix(identifier, "GH-", ""),
      identifier: identifier,
      native_ref: %{"repo" => Config.settings!().tracker.provider["repo"]}
    }

    case WorkerRecovery.context(issue) do
      nil -> Mix.raise("Local GitHub worker recovery is not enabled in this workflow")
      context -> Mix.shell().info(Jason.encode!(%{"path" => context.path, "recovery" => WorkerRecovery.read!(context)}, pretty: true))
    end
  end
end
