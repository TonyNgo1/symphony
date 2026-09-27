defmodule SymphonyElixir.GitHub.AdapterTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.GitHub.{Adapter, AgentTool, Client}

  @states ["Backlog", "Ready", "In progress", "In review", "Integrating", "Human Review", "Done"]

  defmodule FakeClient do
    def fetch_issues_by_states(states), do: {:ok, states}
    def fetch_issues_by_ids(ids), do: {:ok, ids}
  end

  test "2, 5 and 8 worker candidate sets take three reads regardless of unrelated backlog" do
    for count <- [2, 5, 8] do
      selected = Enum.map(2..(count + 1), &item(&1, "Ready"))
      unrelated = Enum.map(100..149, fn number -> put_in(item(number, "Ready"), ["content", "labels"], [%{"name" => "unrelated"}]) end)
      items = [item(1, "In progress", "type:feature") | selected ++ unrelated]
      parents = Map.new(2..(count + 1), &{&1, raw(1, "type:feature")})
      request = api(items, parents: parents)
      counter = :counters.new(1, [])

      counted = fn method, path, params, body, config ->
        :counters.add(counter, 1, 1)
        if path == "/graphql", do: assert(length(body["variables"]["ids"]) == count)
        request.(method, path, params, body, config)
      end

      tracker = Map.put(settings(), :required_labels, ["symphony"])
      assert {:ok, issues} = Client.fetch_issues_by_states_for_test(["Ready"], tracker, counted)
      assert length(issues) == count
      assert Enum.all?(issues, & &1.dispatchable)
      assert :counters.get(counter, 1) == 3
    end
  end

  test "fresh targeted reads observe dependency changes and human pauses" do
    ready = [item(1, "In progress", "type:feature"), item(2, "Ready"), item(3, "Done")]
    opts = [parents: %{2 => raw(1, "type:feature")}, blockers: %{2 => [raw(3)]}]
    assert {:ok, [first]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), api(ready, opts))
    assert first.dispatchable
    reopened = List.replace_at(ready, 2, item(3, "Ready"))
    assert {:ok, [second]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), api(reopened, opts))
    refute second.dispatchable
    paused = List.replace_at(ready, 1, item(2, "Human Review"))
    assert {:ok, [third]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), api(paused, opts))
    refute third.dispatchable
  end

  test "large candidate sets use bounded batches without dropping issues" do
    request = api(Enum.map(1..21, &item(&1, "Ready")))

    counted = fn method, path, params, body, config ->
      if path == "/graphql", do: send(self(), {:batch_size, length(body["variables"]["ids"])})
      request.(method, path, params, body, config)
    end

    assert {:ok, issues} = Client.fetch_issues_by_states_for_test(["Ready"], settings(), counted)
    assert length(issues) == 21
    assert_receive {:batch_size, 10}
    assert_receive {:batch_size, 10}
    assert_receive {:batch_size, 1}
    refute_received {:batch_size, _}
  end

  test "truncated children and parent labels fall back to complete REST reads" do
    items = [item(1, "In progress", "type:feature"), item(2, "Ready")]
    base = api(items, parents: %{2 => raw(1, "type:feature")}, blockers: %{2 => [raw(3)]})

    for connection <- ["subIssues", "parent"] do
      request = fn method, path, params, body, config ->
        result = base.(method, path, params, body, config)
        if path == "/graphql", do: truncate_relationship(result, connection), else: result
      end

      assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), request)
      assert [%{identifier: "GH-3"}] = issue.blocked_by
      refute issue.dispatchable
    end
  end

  defp truncate_relationship({:ok, response}, connection) do
    [node] = response.body["data"]["nodes"]
    path = if connection == "parent", do: ["parent", "labels", "pageInfo", "hasNextPage"], else: [connection, "pageInfo", "hasNextPage"]
    node = put_in(node, path, true)
    {:ok, put_in(response, [:body, "data", "nodes"], [node])}
  end

  test "GraphQL partial errors, missing nodes and malformed relationships fail closed" do
    base = api([item(2, "Ready")])

    for payload <- [
          %{"errors" => [%{"message" => "unavailable"}], "data" => %{"nodes" => []}},
          %{"data" => %{"nodes" => [nil]}},
          %{"data" => %{"nodes" => []}},
          %{"data" => %{"nodes" => [%{"id" => "I_2", "number" => 2, "parent" => nil}]}}
        ] do
      fun = fn method, path, params, body, config ->
        if path == "/graphql", do: ok(payload), else: base.(method, path, params, body, config)
      end

      assert {:error, _} = Client.fetch_issues_by_states_for_test(["Ready"], settings(), fun)
    end
  end

  test "Project selections are read with Status, absent fields default, and malformed selections remain explicit" do
    fields = model_fields()
    fixture = item(1, "Ready", "type:feature")
    selected = %{fixture | "fields" => fixture["fields"] ++ [%{"id" => 11, "value" => %{"id" => "model-small"}}, %{"id" => 12, "value" => "effort-low"}]}
    assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["1"], settings(), api([selected], fields: fields))
    assert issue.model == "small" and issue.reasoning_effort == "low"
    assert_receive {:project_params, %{"fields" => ids}}
    assert Enum.sort(String.split(ids, ",")) == ["10", "11", "12"]
    assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["1"], settings(), api([fixture]))
    assert is_nil(issue.model) and is_nil(issue.reasoning_effort)
    malformed = %{fixture | "fields" => fixture["fields"] ++ [%{"id" => 11, "value" => %{}}]}
    assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["1"], settings(), api([malformed], fields: fields))
    assert issue.model == "<invalid Model selection>"
  end

  test "planner validates both selections before a write and verifies the saved fields" do
    fixture = item(1, "Backlog", "type:feature")
    Process.put(:model_fixture, fixture)
    transport = api([fixture], fields: model_fields())

    request = fn method, path, params, body, config ->
      cond do
        method == "PATCH" ->
          send(self(), {:model_write, body})
          current = Process.get(:model_fixture)
          Process.put(:model_fixture, %{current | "fields" => current["fields"] |> Enum.reject(&(&1["id"] in Enum.map(body["fields"], fn f -> f["id"] end))) |> Kernel.++(body["fields"])})
          ok(%{})

        String.ends_with?(path, "/items") ->
          ok([Process.get(:model_fixture)])

        true ->
          transport.(method, path, params, body, config)
      end
    end

    opts = [tracker_settings: settings(), request_fun: request]
    invalid = Client.update_model_selection("GH-1", %{model: "small", reasoning_effort: "typo"}, opts)
    assert {:error, {:github_model_option_not_found, :reasoning_effort, "typo"}} = invalid
    refute_received {:model_write, _}
    selected = %{model: "small", reasoning_effort: "low"}
    assert {:ok, ^selected} = Client.update_model_selection("GH-1", selected, opts)
    assert_receive {:model_write, %{"fields" => values}}
    assert Enum.sort_by(values, & &1["id"]) == [%{"id" => 11, "value" => "model-small"}, %{"id" => 12, "value" => "effort-low"}]
    assert {:ok, %{model: nil, reasoning_effort: "low"}} = Client.update_model_selection("GH-1", %{model: nil}, opts)
    assert_receive {:model_write, %{"fields" => [%{"id" => 11, "value" => nil}]}}
    assert {:error, _} = Client.update_model_selection("GH-1", %{model: "small"}, Keyword.put(opts, :issue, worker("Ready")))
    refute_received {:model_write, _}
  end

  test "wrong model field type fails configuration reads rather than silently using the default" do
    [model, effort] = model_fields()
    fields = [Map.put(model, "data_type", "text"), effort]
    result = Client.fetch_issues_by_ids_for_test(["1"], settings(), api([], fields: fields))
    assert {:error, {:github_invalid_model_field, "Model"}} = result
  end

  defp model_fields do
    [
      %{"id" => 11, "name" => "Model", "data_type" => "single_select", "options" => [%{"id" => "model-small", "name" => %{"raw" => "small"}}]},
      %{"id" => 12, "name" => "Reasoning effort", "data_type" => "single_select", "options" => [%{"id" => "effort-low", "name" => %{"raw" => "low"}}]}
    ]
  end

  test "adapter delegates reads and keeps auth out of the worker environment" do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FakeClient)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    assert {:ok, ["Ready"]} = Adapter.fetch_issues_by_states(["Ready"])
    assert {:ok, ["2"]} = Adapter.fetch_issues_by_ids(["2"])
    assert "GITHUB_TOKEN" in Adapter.secret_environment_names(settings())
    refute Adapter.execute_agent_tool("unknown", %{}, [])["success"]
    assert {:error, :invalid_github_states} = Adapter.validate_config(%{settings() | active_states: []})
  end

  test "configuration and advertised tools match the project workflow" do
    assert :ok = Adapter.validate_config(settings())

    for state <- ["open", "Todo", "Human Review", "Done", "", 42] do
      assert {:error, :invalid_github_states} = Adapter.validate_config(%{settings() | active_states: [state]})
    end

    assert {:error, :missing_github_active_states} = Adapter.validate_config(%{settings() | active_states: nil})
    assert {:error, :missing_github_terminal_states} = Adapter.validate_config(%{settings() | terminal_states: nil})
    assert {:error, :invalid_github_states} = Adapter.validate_config(%{settings() | terminal_states: ["Ready"]})
    assert Enum.map(Adapter.agent_tool_specs(), & &1["name"]) == ["github_api", "set_project_status", "agent_workpad"]
    assert "SECRET" in Client.secret_environment_names(settings(%{"token" => "$SECRET"}))
    tracker_struct = %SymphonyElixir.Config.Schema.Tracker{provider: %{"token" => "$SECRET"}}
    assert "SECRET" in Client.secret_environment_names(tracker_struct)

    for {override, error} <- [
          {%{"repo" => nil}, :missing_github_repo},
          {%{"repo" => "bad"}, :invalid_github_repo},
          {%{"token" => 42}, :missing_github_token},
          {%{"api_url" => "http://github.test"}, :invalid_github_api_url},
          {%{"project_number" => nil}, :missing_github_project_number},
          {%{"project_owner" => "/bad"}, :invalid_github_project_owner},
          {%{"project_owner_type" => "bad"}, :invalid_github_project_owner_type}
        ] do
      assert {:error, ^error} = Client.validate_settings(settings(override))
    end
  end

  test "project state, branch, hierarchy and native blockers normalize independently" do
    items = [item(1, "In progress", "type:feature"), item(2, "Ready"), item(3, "In progress")]
    fun = api(items, blockers: %{2 => [raw(3)]}, children: %{1 => [raw(2)]}, parents: %{2 => raw(1, "type:feature")})
    assert {:ok, issues} = Client.fetch_issues_by_states_for_test(["Ready"], settings(), fun)
    assert [issue] = issues
    assert issue.state == "Ready"
    assert issue.branch_name == "task/GH-2"
    assert issue.native_ref["parent"]["identifier"] == "GH-1"
    assert [%{identifier: "GH-3", state: "In progress"}] = issue.blocked_by
    refute issue.dispatchable

    done = List.replace_at(items, 2, item(3, "Done"))
    done_api = api(done, blockers: %{2 => [raw(3)]}, parents: %{2 => raw(1, "type:feature")})
    assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), done_api)
    assert issue.dispatchable
    # A native open issue marked Done in this project is a finished dependency.
    assert hd(issue.blocked_by).state == "Done"
  end

  test "worker prompts use parent Project status and distinguish bootstrap from missing review work" do
    previous_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-token")
    on_exit(fn -> restore_env("GITHUB_TOKEN", previous_token) end)
    Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md"))
    :ok = WorkflowStore.force_reload()

    for state <- ["Ready", "In progress", "In review", "Integrating"] do
      items = [item(1, "In progress", "type:feature"), item(2, state)]
      # Native issue state is open; the parent Project state must reach the prompt instead.
      request = api(items, parents: %{2 => raw(1, "type:feature")})
      assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), request)
      assert issue.dispatchable
      prompt = PromptBuilder.build_prompt(issue)
      assert prompt =~ "Parent Project status at dispatch: In progress"
      refute prompt =~ "Parent Project status at dispatch: open"
      assert prompt =~ "Use the tracker context above for startup eligibility"

      if state in ["Ready", "In progress"] do
        assert prompt =~ "create task/GH-2 from origin/feature/GH-1"
        assert prompt =~ "If the workpad records an earlier task commit"
        refute prompt =~ "Required source branch for this phase: task/GH-2"
      else
        assert prompt =~ "Required source branch for this phase: task/GH-2"
        refute prompt =~ "create task/GH-2 from origin/feature/GH-1"
      end

      refute prompt =~ "7. Missing branch,"
    end
  end

  test "foreign repository issue numbers never collide with local project items" do
    foreign = raw(3) |> Map.put("repository_url", "https://api.github.test/repos/other/repo")
    items = [item(1, "In progress", "type:feature"), item(2, "Ready"), item(3, "Done"), put_in(item(2, "Done"), ["content", "repository_url"], "https://api.github.test/repos/other/repo")]
    opts = [parents: %{2 => raw(1, "type:feature")}, blockers: %{2 => [foreign]}]
    assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), api(items, opts))
    assert issue.state == "Ready"
    refute issue.dispatchable
    opts = Keyword.put(opts, :blockers, %{2 => [Map.put(foreign, "state", "closed")]})
    assert {:ok, [issue]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), api(items, opts))
    assert issue.dispatchable
  end

  test "a feature bootstraps Ready, waits for children, then receives feature review" do
    for {state, child_state, expected} <- [
          {"Ready", "Ready", true},
          {"In progress", "Ready", false},
          {"In progress", "Done", true},
          {"In review", "Done", true},
          {"In review", "Integrating", false},
          {"Integrating", "Done", true},
          {"Human Review", "Done", false},
          {"Backlog", "Done", false},
          {"Done", "Done", false}
        ] do
      items = [item(1, state, "type:feature"), item(2, child_state)]
      request = api(items, children: %{1 => [raw(2)]})
      assert {:ok, [feature]} = Client.fetch_issues_by_ids_for_test(["1"], settings(), request)
      assert feature.dispatchable == expected
      assert feature.branch_name == "feature/GH-1"
    end

    request = api([item(1, "In review", "type:feature")])
    assert {:ok, [feature]} = Client.fetch_issues_by_ids_for_test(["1"], settings(), request)
    refute feature.dispatchable
  end

  test "a child needs a managed feature in progress; terminal and human states never dispatch" do
    for parent_state <- ["Ready", "Human Review", "Done", "In review", "Integrating"] do
      items = [item(1, parent_state, "type:feature"), item(2, "Ready")]
      request = api(items, parents: %{2 => raw(1, "type:feature")})
      assert {:ok, [child]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), request)
      refute child.dispatchable
    end

    assert {:ok, [child]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), api([item(2, "Ready")]))
    refute child.dispatchable

    for state <- ["Backlog", "Human Review", "Done"] do
      items = [item(1, "In progress", "type:feature"), item(2, state)]
      request = api(items, parents: %{2 => raw(1, "type:feature")})
      assert {:ok, [child]} = Client.fetch_issues_by_ids_for_test(["2"], settings(), request)
      refute child.dispatchable
    end
  end

  test "a closed child outside the project is not evidence of feature integration" do
    child = Map.put(raw(2), "state", "closed")
    request = api([item(1, "In review", "type:feature")], children: %{1 => [child]})
    assert {:ok, [feature]} = Client.fetch_issues_by_ids_for_test(["1"], settings(), request)
    refute feature.dispatchable
  end

  test "all pages of project items, blockers and subissues are read using Link cursors" do
    base = api([item(1, "In progress", "type:feature"), item(2, "Ready")], parents: %{2 => raw(1, "type:feature")}, overflow: [2])

    fun = fn method, path, params, body, config ->
      case {path, params["after"], params["page"]} do
        {"/users/octo/projectsV2/1/items", nil, _} ->
          ok([item(1, "In progress", "type:feature")], next(path, "after=second&fields=10"))

        {"/users/octo/projectsV2/1/items", "second", _} ->
          ok([item(2, "Ready")])

        {"/repos/octo/repo/issues/2/dependencies/blocked_by", _, nil} ->
          ok([], next(path, "page=2"))

        {"/repos/octo/repo/issues/2/dependencies/blocked_by", _, "2"} ->
          ok([raw(99)])

        _ ->
          base.(method, path, params, body, config)
      end
    end

    assert {:ok, [issue]} = Client.fetch_issues_by_states_for_test(["Ready"], settings(), fun)
    refute issue.dispatchable
    assert hd(issue.blocked_by).identifier == "GH-99"
  end

  test "missing status, archived and draft items cannot masquerade as Ready" do
    items = [Map.put(item(2, "Ready"), "archived_at", "2026-01-01"), Map.put(item(3, "Ready"), "content_type", "DraftIssue"), Map.put(item(4, "Ready"), "fields", [])]
    assert {:ok, []} = Client.fetch_issues_by_states_for_test(["Ready"], settings(), api(items))
    assert {:ok, []} = Client.fetch_issues_by_ids_for_test(["2", "3"], settings(), api(items))
    assert {:ok, []} = Client.fetch_issues_by_ids_for_test([], settings(), fn _, _, _, _, _ -> flunk("unnecessary request") end)
    assert {:error, :invalid_github_issue_id} = Client.fetch_issues_by_ids_for_test(["oops"], settings(), api([]))
  end

  test "relationship errors and incomplete project status configuration fail closed" do
    base = api([item(2, "Ready")], overflow: [2])

    for bad_path <- ["/repos/octo/repo/issues/2/dependencies/blocked_by", "/repos/octo/repo/issues/2/sub_issues"] do
      fun = fn method, path, params, body, config ->
        if path == bad_path, do: {:ok, %{status: 403, body: %{}}}, else: base.(method, path, params, body, config)
      end

      assert {:error, {:github_api_status, 403}} = Client.fetch_issues_by_states_for_test(["Ready"], settings(), fun)
    end

    fun = fn _, _, _, _, _ -> ok([%{"id" => 10, "name" => "Status", "data_type" => "single_select", "options" => []}]) end
    assert {:error, :github_missing_workflow_statuses} = Client.fetch_issues_by_states_for_test(["Ready"], settings(), fun)
  end

  test "status tool binds issue, role and current state; humans alone exit Human Review" do
    worker = worker("In review")
    fun = api([item(2, "In review")])
    opts = [tracker_settings: settings(), request_fun: fun, issue: worker]
    assert {:ok, %{"status" => "In progress"}} = Client.update_project_status("GH-2", "In progress", opts)
    assert_receive {:write, "PATCH", "/users/octo/projectsV2/1/items/102", %{"fields" => [%{"id" => 10, "value" => "In progress"}]}}
    assert {:error, :github_invalid_transition} = Client.update_project_status("GH-2", "Done", opts)
    assert {:error, :github_invalid_transition} = Client.update_project_status("GH-2", "Integrating", Keyword.put(opts, :issue, %{worker | labels: ["type:feature"]}))
    assert {:error, :github_human_review_pause} = Client.update_project_status("GH-2", "Integrating", Keyword.put(opts, :request_fun, api([item(2, "Human Review")])))
    assert {:error, :github_issue_context_required} = Client.update_project_status("GH-2", "Integrating", Keyword.delete(opts, :issue))
    assert {:error, :github_wrong_issue} = Client.update_project_status("GH-2", "Integrating", Keyword.put(opts, :issue, %{worker | id: "99"}))
    assert {:error, :github_stale_worker} = Client.update_project_status("GH-2", "Integrating", Keyword.put(opts, :request_fun, api([item(2, "In progress")])))
  end

  test "Ready worker can finish implementation after claiming, and status retries are idempotent" do
    opts = [tracker_settings: settings(), request_fun: api([item(2, "In progress")]), issue: worker("Ready")]
    assert {:ok, _} = Client.update_project_status("GH-2", "In review", opts)
    assert {:ok, _} = Client.update_project_status("GH-2", "In review", Keyword.put(opts, :request_fun, api([item(2, "In review")])))
    assert {:error, :github_invalid_transition} = Client.update_project_status("GH-2", "In review", Keyword.put(opts, :request_fun, api([item(2, "Ready")])))
  end

  test "workpad paginates, replaces one comment and rejects duplicates and oversized handoffs" do
    body = "## Agent Workpad\nObjective: ship it"
    comment = %{"id" => 77, "body" => body}
    opts = [tracker_settings: settings(), request_fun: api([], comments: [comment])]
    assert {:ok, ^comment} = Client.workpad("GH-2", nil, opts)
    assert {:ok, _} = Client.workpad("GH-2", body, opts)
    assert_receive {:write, "PATCH", "/repos/octo/repo/issues/comments/77", %{"body" => ^body}}
    assert {:ok, _} = Client.workpad("GH-2", body, Keyword.put(opts, :request_fun, api([])))
    assert_receive {:write, "POST", "/repos/octo/repo/issues/2/comments", _}
    assert {:error, :github_duplicate_workpads} = Client.workpad("GH-2", body, Keyword.put(opts, :request_fun, api([], comments: [comment, comment])))
    assert {:error, :github_invalid_workpad} = Client.workpad("GH-2", "## Agent Workpad\n" <> String.duplicate("x\n", 40), opts)
    assert {:error, :github_invalid_workpad} = Client.workpad("GH-2", "diary", opts)
  end

  test "worker REST tool cannot bypass workflow transitions; scoped tools return useful errors" do
    opts = [tracker_settings: settings(), request_fun: api([item(2, "In review")]), issue: worker("In review")]
    assert AgentTool.execute("set_project_status", %{"issue_identifier" => "GH-2", "status" => "In progress"}, opts)["success"]
    assert AgentTool.execute("agent_workpad", %{}, opts)["success"]
    refute AgentTool.execute("github_api", %{"method" => "PATCH", "path" => "/anything"}, opts)["success"]
    refute AgentTool.execute("github_api", %{"method" => "GET", "path" => "https://evil.test"}, opts)["success"]
    refute AgentTool.execute("set_project_status", %{}, opts)["success"]
    refute AgentTool.execute("agent_workpad", %{}, [])["success"]
    refute AgentTool.execute("unknown", %{}, opts)["success"]
    assert AgentTool.execute("github_api", %{"method" => "GET", "path" => "/user"}, github_client: fn _, _, _, _, _ -> ok(%{"login" => "octo"}) end)["success"]
  end

  test "malformed tool inputs and transport errors return failures instead of crashing a worker" do
    for arguments <- [nil, %{}, %{"method" => 42}, %{"method" => "GET"}, %{"method" => "GET", "path" => 42}, %{"method" => "GET", "path" => "/user", "params" => []}] do
      refute AgentTool.execute("github_api", arguments, [])["success"]
    end

    for arguments <- [nil, %{}, %{"issue_identifier" => 42, "status" => "Done"}] do
      refute AgentTool.execute("set_project_status", arguments, [])["success"]
    end

    refute AgentTool.execute("agent_workpad", nil, [])["success"]
    refute AgentTool.execute("agent_workpad", %{"body" => "too vague"}, tracker_settings: settings(), request_fun: api([]), issue: worker("Ready"))["success"]
    arguments = %{"method" => " get ", "path" => " /user ", "params" => %{}}

    transport_results = [
      {:ok, %{status: 500, body: {:unexpected, :payload}}},
      {:error, :missing_github_token},
      {:error, {:github_api_request, :timeout}},
      {:ok, %{status: "invalid", body: %{}}},
      {:ok, %{status: 403, body: %{}}}
    ]

    for result <- transport_results do
      response = AgentTool.execute("github_api", arguments, github_client: fn _, _, _, _, _ -> result end)
      refute response["success"]
    end

    review_opts = [tracker_settings: settings(), request_fun: api([item(2, "In review")]), issue: worker("In review")]
    response = AgentTool.execute("set_project_status", %{"issue_identifier" => "GH-2", "status" => "Done"}, review_opts)

    refute response["success"]
  end

  defp settings(overrides \\ %{}),
    do: %{
      active_states: ["Ready", "In progress", "In review", "Integrating"],
      terminal_states: ["Done"],
      provider: Map.merge(%{"repo" => "octo/repo", "token" => "test-token", "project_number" => 1}, overrides)
    }

  defp worker(state), do: %Issue{id: "2", identifier: "GH-2", state: state, labels: ["type:task"]}

  defp raw(number, type \\ "type:task"),
    do: %{
      "id" => 1000 + number,
      "node_id" => "I_#{number}",
      "number" => number,
      "title" => "Issue #{number}",
      "body" => "Acceptance: tested",
      "state" => "open",
      "labels" => [%{"name" => type}, %{"name" => "symphony"}],
      "repository_url" => "https://api.github.test/repos/octo/repo",
      "html_url" => "https://github.test/octo/repo/issues/#{number}"
    }

  defp item(number, state, type \\ "type:task"),
    do: %{
      "id" => 100 + number,
      "content_type" => "Issue",
      "content" => raw(number, type),
      "fields" => [%{"id" => 10, "value" => %{"id" => state, "name" => %{"raw" => state}}}]
    }

  defp ok(body, headers \\ %{}), do: {:ok, %{status: 200, body: body, headers: headers}}
  defp next(path, query), do: %{"link" => ["<https://api.github.test#{path}?#{query}>; rel=\"next\""]}

  defp api(items, opts \\ []) do
    fn method, path, params, body, _config ->
      cond do
        path == "/graphql" ->
          nodes = Enum.map(body["variables"]["ids"], &graph_node(&1, opts))
          ok(%{"data" => %{"nodes" => nodes}})

        method != "GET" ->
          send(self(), {:write, method, path, body})
          ok(%{})

        String.ends_with?(path, "/fields") ->
          ok([%{"id" => 10, "name" => "Status", "data_type" => "single_select", "options" => Enum.map(@states, &%{"id" => &1, "name" => %{"raw" => &1}})}] ++ Keyword.get(opts, :fields, []))

        String.ends_with?(path, "/items") ->
          send(self(), {:project_params, params})
          ok(items)

        String.ends_with?(path, "/comments") ->
          ok(Keyword.get(opts, :comments, []))

        true ->
          relationship_response(path, opts)
      end
    end
  end

  defp relationship_response(path, opts) do
    [_, number, suffix] = Regex.run(~r{/issues/(\d+)/(.*)$}, path)
    number = String.to_integer(number)

    case suffix do
      "dependencies/blocked_by" -> ok(Keyword.get(opts, :blockers, %{})[number] || [])
      "sub_issues" -> ok(Keyword.get(opts, :children, %{})[number] || [])
      "parent" -> parent_response(Keyword.get(opts, :parents, %{})[number])
    end
  end

  defp graph_node("I_" <> number, opts) do
    number = String.to_integer(number)
    blockers = Keyword.get(opts, :blockers, %{})[number] || []
    children = Keyword.get(opts, :children, %{})[number] || []
    parent = Keyword.get(opts, :parents, %{})[number]

    %{
      "id" => "I_#{number}",
      "number" => number,
      "blockedBy" => graph_connection(Enum.map(blockers, &graph_issue/1), number in Keyword.get(opts, :overflow, [])),
      "subIssues" => graph_connection(Enum.map(children, &graph_issue/1)),
      "parent" => if(parent, do: graph_issue(parent))
    }
  end

  defp parent_response(nil), do: {:ok, %{status: 404, body: %{}}}
  defp parent_response(parent), do: ok(parent)

  defp graph_connection(nodes, more \\ false), do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => more}}

  defp graph_issue(raw) do
    %{
      "number" => raw["number"],
      "state" => String.upcase(raw["state"]),
      "url" => raw["html_url"],
      "repository" => %{"nameWithOwner" => URI.parse(raw["repository_url"]).path |> String.replace_prefix("/repos/", "")},
      "labels" => graph_connection(raw["labels"])
    }
  end
end
