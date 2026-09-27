# Read-only preflight. Never start the Symphony application/scheduler here.
{:ok, _} = Application.ensure_all_started(:req)
{:ok, _} = Application.ensure_all_started(:yaml_elixir)
{:ok, _} = SymphonyElixir.GitHub.Http.start_link([])
SymphonyElixir.Workflow.set_workflow_file_path(System.fetch_env!("SYMPHONY_CHECK_WORKFLOW"))
:ok = SymphonyElixir.Config.validate!()
config = SymphonyElixir.Config.settings!()
SymphonyElixir.Tracker.bind_agent_tools()
states = ["Backlog", "Ready", "In progress", "In review", "Integrating", "Human Review", "Done"]

case SymphonyElixir.GitHub.Client.fetch_issues_by_states(states) do
  {:ok, issues} ->
    Enum.each(issues, fn issue ->
      SymphonyElixir.PromptBuilder.build_prompt(issue)
      IO.puts("#{issue.identifier}: #{issue.state}; dispatchable=#{issue.dispatchable}; blockers=#{length(issue.blocked_by)}")
    end)

    IO.puts("Preflight OK: #{length(issues)} project issues; #{config.agent.max_concurrent_agents} workers; no agents launched.")

  {:error, reason} ->
    IO.puts(:stderr, "Preflight failed: #{inspect(reason)}")
    System.halt(1)
end
