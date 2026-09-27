defmodule SymphonyElixir.ModelSelectionTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.ModelSelection
  alias SymphonyElixir.GitHub.Acceptance

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-models-#{System.unique_integer([:positive])}") |> String.replace("\\", "/")
    File.mkdir_p!(root)
    fixture = Path.expand("test/fixtures/model_app_server.py")
    python = if match?({:win32, _}, :os.type()), do: ~s("#{System.find_executable("py")}" -3), else: "python3"
    command = ~s(#{python} "#{fixture}" "#{root}") |> String.replace("\\", "/")

    config = [
      tracker_active_states: ["Ready", "In progress", "In review", "Integrating"],
      workspace_root: root,
      tracker_kind: "memory",
      codex_command: command,
      codex_model: "standard",
      codex_reasoning_effort: "medium",
      codex_review_model: "reviewer",
      codex_review_reasoning_effort: "high",
      codex_integration_model: "integrator",
      codex_integration_reasoning_effort: "high"
    ]

    write_workflow_file!(Workflow.workflow_file_path(), config)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, config: config}
  end

  test "two concurrent issues send distinct selections and roles use independent defaults", %{root: root} do
    jobs =
      for {id, state, model, effort} <- [
            {"1", "Ready", "small", "low"},
            {"2", "In progress", "standard", "high"},
            {"3", "In review", "small", "low"},
            {"4", "Integrating", "small", "low"}
          ] do
        Task.async(fn ->
          workspace = Path.join(root, "GH-#{id}")
          File.mkdir_p!(workspace)
          issue = %Issue{id: id, identifier: "GH-#{id}", state: state, model: model, reasoning_effort: effort}
          AppServer.run(workspace, "no-op", issue)
        end)
      end

    for job <- jobs, do: assert({:ok, _} = Task.await(job, 15_000))
    calls = requests(root)
    turns = for %{"method" => "turn/start", "params" => params} <- calls, do: {params["model"], params["effort"]}
    assert Enum.sort(turns) == Enum.sort([{"small", "low"}, {"standard", "high"}, {"reviewer", "high"}, {"integrator", "high"}])
    assert Enum.count(calls, &(&1["method"] == "model/list")) == 8
    assert Enum.sort(for %{"method" => "thread/start", "params" => p} <- calls, do: p["model"]) == ~w(integrator reviewer small standard)
  end

  test "a live worker pins its selection across config reload and issue edits", %{root: root, config: config} do
    workspace = Path.join(root, "GH-1")
    File.mkdir_p!(workspace)
    issue = %Issue{id: "1", identifier: "GH-1", state: "Ready", model: "small", reasoning_effort: "low"}
    assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(config, :codex_model, "integrator"))
      assert {:ok, _} = AppServer.run_turn(session, "no-op", %{issue | model: "standard", reasoning_effort: "high"})
      assert session.model_selection == %{model: "small", effort: "low", role: "implementation"}
    after
      AppServer.stop_session(session)
    end

    [params] = for %{"method" => "turn/start", "params" => params} <- requests(root), do: params
    assert params["model"] == "small" and params["effort"] == "low"
  end

  test "invalid selection never starts a model turn", %{root: root} do
    workspace = Path.join(root, "GH-1")
    File.mkdir_p!(workspace)

    for {model, effort} <- [{"missing", "medium"}, {"small", "unsupported"}] do
      issue = %Issue{id: "1", identifier: "GH-1", state: "Ready", model: model, reasoning_effort: effort}
      assert {:error, {:model_selection_invalid, _, _}} = AppServer.run(workspace, "no-op", issue)
    end

    refute Enum.any?(requests(root), &(&1["method"] in ["thread/start", "turn/start"]))
  end

  test "blank fields use configured defaults; review ignores implementation settings" do
    blank = %Issue{model: " ", reasoning_effort: ""}
    review = %Issue{state: "In review", model: "missing", reasoning_effort: "bad"}
    assert ModelSelection.requested(blank) == %{model: "standard", effort: "medium", role: "implementation"}
    assert ModelSelection.requested(review) == %{model: "reviewer", effort: "high", role: "review"}
  end

  test "asset generation overrides project model and effort on the actual app-server wire", %{root: root, config: config} do
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(config, :codex_command, config[:codex_command] <> " --with-astra"))

    for state <- ["Ready", "In progress"] do
      workspace = Path.join(root, String.replace(state, " ", "-"))
      File.mkdir_p!(workspace)
      issue = %Issue{state: state, labels: ["type:task", "asset-generation"], model: "small", reasoning_effort: "low"}
      assert {:ok, _} = AppServer.run(workspace, "Generate an asset", issue)
    end

    calls = requests(root)
    assert Enum.count(calls, &(&1["method"] == "turn/start")) == 2
    for %{"method" => "thread/start", "params" => params} <- calls, do: assert(params["model"] == "gpt-6-astra")
    for %{"method" => "turn/start", "params" => params} <- calls, do: assert(params["model"] == "gpt-6-astra" and params["effort"] == "high")
  end

  test "human asset contracts also route implementation to Astra without changing review or integration defaults" do
    criterion = %{
      "id" => "A1",
      "description" => "Approved visual",
      "validation" => %{
        "kind" => "human_asset",
        "manifest" => "reviews/art/v1/manifest.json",
        "reviewers" => ["human"],
        "instructions" => "Inspect"
      }
    }

    issue = %Issue{state: "Ready", model: "small", reasoning_effort: "low", description: Acceptance.render([criterion])}
    assert ModelSelection.requested(issue) == %{role: "implementation", model: "gpt-6-astra", effort: "high"}
    assert ModelSelection.requested(%{issue | state: "In review", labels: ["asset-generation"]}).model == "reviewer"
    assert ModelSelection.requested(%{issue | state: "Integrating", labels: ["asset-generation"]}).model == "integrator"
    ordinary = %{criterion | "validation" => %{"kind" => "review", "instructions" => "Run tests"}}
    assert ModelSelection.requested(%{issue | description: Acceptance.render([ordinary])}).model == "small"
    # The explicit label remains authoritative even if a contract needs repair.
    assert ModelSelection.requested(%{issue | labels: ["asset-generation"], description: "malformed"}).model == "gpt-6-astra"
  end

  test "unavailable Astra blocks asset generation without substituting a cheaper model", %{root: root} do
    workspace = Path.join(root, "asset")
    File.mkdir_p!(workspace)
    issue = %Issue{state: "Ready", labels: ["asset-generation"], model: "standard"}
    assert {:error, {:model_selection_invalid, _, %{model: "gpt-6-astra", effort: "high"}}} = AppServer.run(workspace, "Generate an asset", issue)
    refute Enum.any?(requests(root), &(&1["method"] in ["thread/start", "turn/start"]))
  end

  test "adding asset scope rotates an ordinary worker before its next implementation turn", %{root: root, config: config} do
    write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(config, :codex_command, config[:codex_command] <> " --with-astra"))
    issue = %Issue{id: "8", identifier: "GH-8", state: "In progress", model: "small", reasoning_effort: "low"}
    asset = %{issue | labels: ["asset-generation"]}
    assert :ok = AgentRunner.run(issue, nil, max_turns: 3, issue_state_fetcher: fn _ -> {:ok, [asset]} end)
    assert Enum.count(requests(root), &(&1["method"] == "turn/start")) == 1
    assert :ok = AgentRunner.run(asset, nil, max_turns: 1, issue_state_fetcher: fn _ -> {:ok, [%{asset | state: "Done"}]} end)
    turns = for %{"method" => "turn/start", "params" => params} <- requests(root), do: params["model"]
    assert Enum.sort(turns) == ["gpt-6-astra", "small"]
  end

  test "agent runner propagates issue model fields through the complete worker entry point", %{root: root} do
    issue = %Issue{id: "7", identifier: "GH-7", state: "Ready", model: "small", reasoning_effort: "low"}
    fetcher = fn _ -> {:ok, [%{issue | state: "Done"}]} end
    assert :ok = AgentRunner.run(issue, nil, max_turns: 1, issue_state_fetcher: fetcher)
    [params] = for %{"method" => "turn/start", "params" => params} <- requests(root), do: params
    assert params["model"] == "small" and params["effort"] == "low"
  end

  test "parent reviews use separate wire settings while child reviews keep review defaults", %{root: root, config: config} do
    config = config |> Keyword.put(:codex_parent_review_model, "integrator") |> Keyword.put(:codex_parent_review_reasoning_effort, "high")
    write_workflow_file!(Workflow.workflow_file_path(), config)

    for {id, labels, expected} <- [{"parent", ["type:feature"], "integrator"}, {"child", ["type:task"], "reviewer"}] do
      workspace = Path.join(root, id)
      File.mkdir_p!(workspace)
      issue = %Issue{id: id, identifier: id, state: "In review", labels: labels, model: "small", reasoning_effort: "low"}
      assert {:ok, _} = AppServer.run(workspace, "no-op", issue)
      [params] = for %{"method" => "turn/start", "params" => params} <- requests(root), params["cwd"] == workspace, do: params
      assert params["model"] == expected and params["effort"] == "high"
    end
  end

  test "parent review overrides fall back per field and only affect future review workers", %{root: root, config: config} do
    issue = %Issue{id: "1", identifier: "GH-1", state: "In review", labels: ["type:feature"], model: "small", reasoning_effort: "low"}
    assert ModelSelection.requested(issue) == %{role: "review", model: "reviewer", effort: "high"}
    config = Keyword.put(config, :codex_parent_review_model, "integrator")
    write_workflow_file!(Workflow.workflow_file_path(), config)
    assert ModelSelection.requested(issue) == %{role: "review", model: "integrator", effort: "high"}
    assert ModelSelection.requested(%{issue | state: "Ready"}).model == "small"
    assert ModelSelection.requested(%{issue | state: "Integrating"}).model == "integrator"
    workspace = Path.join(root, "GH-1")
    File.mkdir_p!(workspace)
    assert {:ok, session} = AppServer.start_session(workspace, issue: issue)

    try do
      config = config |> Keyword.put(:codex_parent_review_model, " ") |> Keyword.put(:codex_parent_review_reasoning_effort, "medium")
      write_workflow_file!(Workflow.workflow_file_path(), config)
      assert ModelSelection.requested(issue) == %{role: "review", model: "reviewer", effort: "medium"}
      assert {:ok, _} = AppServer.run_turn(session, "no-op", issue)
      assert session.model_selection == %{role: "review", model: "integrator", effort: "high"}
    after
      AppServer.stop_session(session)
    end
  end

  test "a server substituting another model is rejected before the first turn", %{root: root, config: config} do
    command = config[:codex_command] <> " --wrong-model"
    updated = config |> Keyword.put(:codex_command, command) |> Keyword.put(:codex_model, nil)
    write_workflow_file!(Workflow.workflow_file_path(), updated)
    workspace = Path.join(root, "GH-1")
    File.mkdir_p!(workspace)
    assert {:error, {:model_selection_invalid, _, request}} = AppServer.run(workspace, "no-op", %Issue{})
    assert request == %{model: nil, effort: "medium", role: "implementation"}
    refute Enum.any?(requests(root), &(&1["method"] == "turn/start"))
  end

  test "runtime events carry selection and failed workers preserve the typed block reason", %{root: root} do
    workspace = Path.join(root, "GH-1")
    File.mkdir_p!(workspace)
    receiver = self()
    assert {:ok, _} = AppServer.run(workspace, "no-op", %Issue{}, on_message: &send(receiver, {:event, &1}))
    assert_receive {:event, %{event: :session_started, model_selection: %{model: "standard", effort: "medium"}}}
    bad = %Issue{id: "2", identifier: "GH-2", state: "Ready", model: "missing"}
    assert {:model_selection_invalid, _, _} = catch_exit(AgentRunner.run(bad))
  end

  test "invalid model blocks only its issue without retries, then a field correction releases it" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    pid = start_supervised!({Orchestrator, name: __MODULE__.Scheduler, task_supervisor: supervisor})
    {:ok, task} = Task.Supervisor.start_child(supervisor, fn -> Process.sleep(:infinity) end)
    issue = %Issue{id: "1", identifier: "GH-1", state: "Ready", dispatchable: true, model: "missing"}
    entry = %{pid: task, ref: Process.monitor(task), identifier: "GH-1", issue: issue, session_id: nil}
    entry = Map.merge(entry, %{started_at: DateTime.utc_now(), retry_attempt: 0})
    selection = ModelSelection.requested(issue)
    :sys.replace_state(pid, &%{&1 | running: %{"1" => entry}, claimed: MapSet.new(["1"])})
    send(pid, {:DOWN, entry.ref, :process, task, {:model_selection_invalid, "unavailable", selection}})
    snapshot = GenServer.call(pid, :snapshot)
    assert [%{error: "unavailable", model_selection: ^selection}] = snapshot.blocked
    assert snapshot.retrying == [] and is_nil(snapshot.dispatch_paused)
    state = :sys.get_state(pid)
    assert Orchestrator.reconcile_blocked_issue_states_for_test([issue], state).blocked != %{}
    corrected = %{issue | model: "small"}
    assert Orchestrator.reconcile_blocked_issue_states_for_test([corrected], state).blocked == %{}
    changed_phase = %{issue | state: "In review"}
    assert Orchestrator.reconcile_blocked_issue_states_for_test([changed_phase], state).blocked == %{}
  end

  defp requests(root), do: Path.wildcard(Path.join(root, "*.jsonl")) |> Enum.flat_map(&(File.read!(&1) |> String.split("\n", trim: true) |> Enum.map(fn line -> Jason.decode!(line) end)))
end
