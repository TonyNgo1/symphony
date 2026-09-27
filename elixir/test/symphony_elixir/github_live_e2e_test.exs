defmodule SymphonyElixir.GitHub.LiveE2ETest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.GitHub.Client, as: GitHubClient

  @moduletag :live_e2e
  @moduletag timeout: 300_000
  @tag skip: System.get_env("SYMPHONY_RUN_GITHUB_LIVE_E2E") != "1"
  test "reads a real GitHub project and validates the execution contract without mutations" do
    tracker = %{
      active_states: ["Ready", "In progress", "In review", "Integrating"],
      terminal_states: ["Done"],
      provider: %{
        "repo" => System.fetch_env!("SYMPHONY_LIVE_GITHUB_REPO"),
        "token" => System.fetch_env!("GITHUB_TOKEN"),
        "project_number" => System.fetch_env!("SYMPHONY_LIVE_GITHUB_PROJECT_NUMBER") |> String.to_integer(),
        "project_owner" => System.get_env("SYMPHONY_LIVE_GITHUB_PROJECT_OWNER"),
        "project_owner_type" => System.get_env("SYMPHONY_LIVE_GITHUB_PROJECT_OWNER_TYPE", "user")
      }
    }

    request = fn method, path, params, body, _config ->
      GitHubClient.request(method, path, params, body, tracker_settings: tracker)
    end

    states = ["Backlog", "Ready", "In progress", "In review", "Integrating", "Human Review", "Done"]
    assert {:ok, issues} = GitHubClient.fetch_issues_by_states_for_test(states, tracker, request)

    for issue <- issues do
      assert issue.state in states
      assert issue.native_ref["repo"] == tracker.provider["repo"]
      if issue.state in ["Backlog", "Human Review", "Done"], do: refute(issue.dispatchable)

      assert {:ok, [_refreshed]} =
               GitHubClient.fetch_issues_by_ids_for_test([issue.id], tracker, request)
    end
  end
end
