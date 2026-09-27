defmodule Mix.Tasks.Github.Models do
  use Mix.Task
  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.GitHub.Http
  alias SymphonyElixir.Workflow
  alias SymphonyElixir.WorkflowStore
  @switches [workflow: :string, model: :string, effort: :string, clear_model: :boolean, clear_effort: :boolean]

  @shortdoc "Read or assign an issue's implementation model fields (no scheduler started)"
  @moduledoc """
  GITHUB_TOKEN must be in the environment. Examples:

      mix github.models GH-123 --workflow WORKFLOW.md
      mix github.models GH-123 --model gpt-6-sol --effort medium
      mix github.models GH-123 --clear-model --clear-effort

  Omitting both options reads the fields. Field options must already exist in the
  project. This command never creates fields, changes status, or starts workers.
  """

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [] or length(argv) != 1, do: Mix.raise(@moduledoc)
    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:req)
    if opts[:workflow], do: Workflow.set_workflow_file_path(opts[:workflow])
    :ok = WorkflowStore.force_reload()
    if is_nil(Process.whereis(Http)), do: {:ok, _} = Http.start_link([])
    [identifier] = argv
    selection = selection(opts)

    case apply_selection(identifier, selection) do
      {:ok, value} when is_map(value) -> Mix.shell().info(Jason.encode!(value, pretty: true))
      error -> Mix.raise("Model selection failed: #{inspect(error)}")
    end
  end

  defp selection(opts) do
    Enum.reduce([{:model, :model, :clear_model}, {:effort, :reasoning_effort, :clear_effort}], %{}, fn {flag, key, clear}, acc ->
      case {opts[clear], Keyword.fetch(opts, flag)} do
        {true, {:ok, _}} -> Mix.raise("Choose a value or clear flag, not both")
        {true, :error} -> Map.put(acc, key, nil)
        {_, {:ok, value}} -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp apply_selection(identifier, selection) when map_size(selection) == 0 do
    with {:ok, [issue]} <- client().fetch_issues_by_ids([identifier]), do: {:ok, Map.take(issue, [:model, :reasoning_effort])}
  end

  defp apply_selection(identifier, selection), do: client().update_model_selection(identifier, selection)
  defp client, do: Application.get_env(:symphony_elixir, :github_client_module, Client)
end
