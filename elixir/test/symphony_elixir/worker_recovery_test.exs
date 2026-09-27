defmodule SymphonyElixir.WorkerRecoveryTest do
  use SymphonyElixir.TestSupport
  alias Mix.Tasks.Github.Handoff
  alias SymphonyElixir.TestSupport.Platform
  alias SymphonyElixir.{WorkerRecovery, WorkspaceFingerprint}
  import ExUnit.CaptureIO

  defmodule Board do
    def workpad(_id, nil, _opts), do: {:ok, %{"body" => "## Agent Workpad\nNext: inspect\nReview: old"}}

    def workpad(_id, body, opts) do
      send(self(), {:pad, body, opts})
      {:ok, %{}}
    end

    def update_project_status(id, status, _opts) do
      send(self(), {:status, id, status})
      if Process.get(:board_failure), do: {:error, :unavailable}, else: {:ok, %{}}
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-recovery-#{System.unique_integer([:positive])}") |> String.replace("\\", "/")
    workspace = Path.join(root, "GH-2")
    File.mkdir_p!(workspace)
    git(workspace, ["init", "-q"])
    File.write!(Path.join(workspace, "tracked.txt"), "baseline\n")
    git(workspace, ["add", "."])
    git(workspace, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "baseline"])
    configure(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, workspace: workspace, context: WorkerRecovery.context(issue())}
  end

  test "task IDs, role, commits and workpad survive rotation and config reload", %{context: ctx, workspace: workspace} do
    assert :ok = WorkerRecovery.prepare(ctx, Board)
    start(ctx, workspace)
    WorkerRecovery.session!(ctx, %{thread_id: "thread-1", workspace: workspace})
    WorkerRecovery.checkpoint!(ctx, "## Agent Workpad\nNext: implement boundary case", 3)
    refute WorkerRecovery.checkpoint_due?(ctx, 3, 20)
    assert WorkerRecovery.checkpoint_due?(ctx, 20, 20)
    WorkerRecovery.finish!(ctx, :ok, issue())
    :ok = WorkflowStore.force_reload()
    current = WorkerRecovery.context(issue())
    start(current, workspace)
    WorkerRecovery.session!(current, %{thread_id: "thread-2", workspace: workspace})
    state = WorkerRecovery.read!(current)
    assert state["latest"]["thread_id"] == "thread-2"
    assert hd(state["attempts"])["thread_id"] == "thread-1"
    assert hd(state["attempts"])["snapshot"]["head"] == WorkspaceFingerprint.capture(workspace)["head"]
    assert state["workpad"] =~ "boundary case"
    WorkerRecovery.finish!(current, :quota)
  end

  test "consecutive failures pause and clear approval; human release resets limits", %{context: ctx} do
    for _ <- 1..3 do
      WorkerRecovery.start!(ctx)
      WorkerRecovery.finish!(ctx, :failed)
    end

    assert {:error, {:worker_recovery_pause, "consecutive worker failures"}} = WorkerRecovery.prepare(ctx, Board)
    assert_receive {:pad, body, opts}
    refute body =~ "Review: old"
    assert body =~ "consecutive worker failures"
    assert opts[:review_record] == nil
    assert_receive {:status, "GH-2", "Human Review"}
    WorkerRecovery.observe(%{ctx | issue: issue("Human Review")})
    assert :ok = WorkerRecovery.prepare(ctx, Board)
    assert WorkerRecovery.read!(ctx)["failures"] == 0
  end

  test "a failed board write remains paused on disk and is retried without launching workers", %{context: ctx} do
    for _ <- 1..3 do
      WorkerRecovery.start!(ctx)
      WorkerRecovery.finish!(ctx, :failed)
    end

    Process.put(:board_failure, true)
    assert {:error, {:worker_recovery_pause, _}} = WorkerRecovery.prepare(ctx, Board)
    refute WorkerRecovery.read!(ctx)["pause_applied"]
    assert {:error, {:worker_recovery_pause, _}} = WorkerRecovery.prepare(WorkerRecovery.context(issue()), Board)
    Process.delete(:board_failure)
    assert {:error, {:worker_recovery_pause, _}} = WorkerRecovery.prepare(ctx, Board)
    assert WorkerRecovery.read!(ctx)["pause_applied"]
  end

  test "workpad churn cannot reset no-progress, but actual repository changes do", %{context: ctx, workspace: workspace} do
    for n <- 1..2 do
      start(ctx, workspace)
      WorkerRecovery.checkpoint!(ctx, "## Agent Workpad\nNext: thinking #{n}", 1)
      WorkerRecovery.finish!(ctx, :ok, issue())
    end

    assert WorkerRecovery.read!(ctx)["no_progress"] == 2
    start(ctx, workspace)
    File.write!(Path.join(workspace, "tracked.txt"), "implementation\n")
    WorkerRecovery.finish!(ctx, :ok, issue())
    assert WorkerRecovery.read!(ctx)["no_progress"] == 0

    for _ <- 1..3 do
      start(ctx, workspace)
      WorkerRecovery.finish!(ctx, :ok, issue())
    end

    assert {:error, {:worker_recovery_pause, "worker runs without repository progress"}} = WorkerRecovery.prepare(ctx, Board)
  end

  test "review/integration ping-pong is bounded even when commits change", %{context: ctx, workspace: workspace} do
    ctx = %{ctx | issue: issue("In review")}

    for n <- 1..3 do
      start(ctx, workspace)
      File.write!(Path.join(workspace, "tracked.txt"), "revision #{n}")
      WorkerRecovery.finish!(ctx, :ok, issue())
    end

    assert WorkerRecovery.read!(ctx)["reworks"] == 3
    assert {:error, {:worker_recovery_pause, "repeated review/integration rework"}} = WorkerRecovery.prepare(ctx, Board)
  end

  test "live owner prevents duplicate dispatch after scheduler restart; dead owner counts once", %{context: ctx} do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        WorkerRecovery.start!(ctx)
        send(parent, :started)
        receive do: (:stop -> :ok)
      end)

    assert_receive :started
    assert {:error, :recovery_worker_still_running} = WorkerRecovery.prepare(ctx, Board)
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    assert :ok = WorkerRecovery.prepare(ctx, Board)
    assert WorkerRecovery.read!(ctx)["failures"] == 1
    assert :ok = WorkerRecovery.prepare(ctx, Board)
    assert WorkerRecovery.read!(ctx)["failures"] == 1
  end

  test "quota is not an ordinary failure and history is bounded", %{context: ctx} do
    for _ <- 1..24 do
      WorkerRecovery.start!(ctx)
      WorkerRecovery.finish!(ctx, :quota)
    end

    state = WorkerRecovery.read!(ctx)
    assert state["failures"] == 0
    assert state["no_progress"] == 0
    assert length(state["attempts"]) == 19
  end

  test "corrupt state and linked recovery directories fail closed", %{context: ctx, root: root} do
    :ok = WorkerRecovery.prepare(ctx, Board)

    for body <- ["not-json", "{}", ~s({"version":1,"active":false,"attempts":[],"failures":"oops"})] do
      File.write!(ctx.path, body)
      assert {:error, :recovery_state_unavailable} = WorkerRecovery.prepare(ctx, Board)
      assert :ok = WorkerRecovery.observe(%{ctx | issue: issue("Human Review")})
    end

    File.rm!(ctx.path)
    File.mkdir!(ctx.path)
    assert {:error, :recovery_state_unavailable} = WorkerRecovery.prepare(ctx, Board)
    other = Path.join(root, "other")
    File.mkdir!(other)
    link = Path.join(root, "link")
    Platform.directory_link!(other, link)
    linked = %{ctx | path: Path.join(link, "state.json")}
    assert {:error, :recovery_state_unavailable} = WorkerRecovery.prepare(linked, Board)
    refute File.exists?(Path.join(other, "state.json"))
  end

  test "disabled and remote workers preserve existing behavior", %{root: root, context: ctx} do
    assert is_nil(WorkerRecovery.context(issue(), "remote"))
    assert is_nil(WorkerRecovery.context(%{issue() | native_ref: nil}))
    assert :ok = WorkerRecovery.observe(ctx)
    configure(root, recovery_enabled: false)
    assert is_nil(WorkerRecovery.context(issue()))
    assert :ok = WorkerRecovery.prepare(nil)
    assert :ok = WorkerRecovery.start!(nil)
    assert :ok = WorkerRecovery.workspace!(nil, "unused")
    assert :ok = WorkerRecovery.session!(nil, %{})
    assert :ok = WorkerRecovery.checkpoint!(nil, "", 1)
    refute WorkerRecovery.checkpoint_due?(nil, 1, 1)
    assert :ok = WorkerRecovery.finish!(nil, :ok)
    assert :ok = WorkerRecovery.observe(nil)
  end

  test "fingerprint covers staged and untracked changes without treating ignored caches as progress", %{workspace: workspace} do
    before = WorkspaceFingerprint.capture(workspace)
    refute before["dirty"]
    untracked = Path.join(workspace, "new.txt")
    File.write!(untracked, "one")
    one = WorkspaceFingerprint.capture(workspace)
    File.write!(untracked, "two")
    refute WorkspaceFingerprint.capture(workspace)["fingerprint"] == one["fingerprint"]
    File.rm!(untracked)
    File.write!(Path.join(workspace, "tracked.txt"), "staged\n")
    git(workspace, ["add", "tracked.txt"])
    File.write!(Path.join(workspace, "tracked.txt"), "baseline\n")
    staged = WorkspaceFingerprint.capture(workspace)
    assert staged["dirty"]
    refute before["fingerprint"] == staged["fingerprint"]
    File.write!(Path.join(workspace, ".git/info/exclude"), "cache.tmp\n")
    File.write!(Path.join(workspace, "cache.tmp"), "ignored")
    assert WorkspaceFingerprint.capture(workspace) == staged
    assert_raise RuntimeError, ~r/snapshot failed/, fn -> WorkspaceFingerprint.capture(Path.dirname(workspace)) end
  end

  test "a dead worker after a role transition does not count as an ordinary failure", %{context: ctx} do
    ctx = %{ctx | issue: issue("In review")}
    {pid, monitor} = spawn_monitor(fn -> WorkerRecovery.start!(ctx) end)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    resumed = %{ctx | issue: issue()}
    assert :ok = WorkerRecovery.prepare(resumed, Board)
    state = WorkerRecovery.read!(resumed)
    assert state["failures"] == 0
    assert state["reworks"] == 1
  end

  test "untracked directory links do not read or fingerprint outside content", %{root: root, workspace: workspace} do
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    file = Path.join(outside, "private.txt")
    File.write!(file, "first")
    Platform.directory_link!(outside, Path.join(workspace, "external"))
    snapshot = WorkspaceFingerprint.capture(workspace)
    File.write!(file, "second")
    assert WorkspaceFingerprint.capture(workspace) == snapshot
  end

  test "malformed stale owner identity does not prevent crash recovery", %{context: ctx} do
    WorkerRecovery.start!(ctx)
    state = WorkerRecovery.read!(ctx) |> Map.put("owner", "invalid")
    File.write!(ctx.path, Jason.encode!(state))
    assert :ok = WorkerRecovery.prepare(ctx, Board)
    assert WorkerRecovery.read!(ctx)["failures"] == 1
  end

  test "dispatch enforces persisted limits and human observation releases the local block", %{context: ctx} do
    for _ <- 1..3 do
      WorkerRecovery.start!(ctx)
      WorkerRecovery.finish!(ctx, :failed)
    end

    state = %Orchestrator.State{max_concurrent_agents: 2}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [issue()])
    blocked = Orchestrator.handle_retry_issue_lookup_for_test(issue(), state, "2", 1, %{})
    assert blocked.running == %{}
    assert blocked.blocked["2"].recovery_block
    assert WorkerRecovery.read!(ctx)["paused"]
    paused = %{issue("Human Review") | dispatchable: false}
    released = Orchestrator.reconcile_blocked_issue_states_for_test([paused], blocked)
    assert released.blocked == %{}
    assert WorkerRecovery.read!(ctx)["pause_applied"]
    assert :ok = WorkerRecovery.prepare(ctx, Board)
    assert WorkerRecovery.read!(ctx)["failures"] == 0
  end

  test "quota exhaustion never triggers a final checkpoint or consumes ordinary retries", %{root: root} do
    configure_peer(root, "quota")
    assert catch_exit(AgentRunner.run(issue(), self(), max_turns: 1)) == :usage_limit_exceeded
    assert_receive {:usage_limit_exceeded, "2"}
    state = WorkerRecovery.read!(WorkerRecovery.context(issue()))
    assert state["failures"] == 0
    assert state["latest"]["outcome"] == "quota"
  end

  test "requests for human input do not consume ordinary failure retries", %{root: root} do
    configure_peer(root, "input")
    assert_raise RuntimeError, ~r/turn_input_required/, fn -> AgentRunner.run(issue(), nil, max_turns: 1) end
    state = WorkerRecovery.read!(WorkerRecovery.context(issue()))
    assert state["failures"] == 0
    assert state["latest"]["outcome"] == "blocked"
  end

  test "normal rotation enforces a missing checkpoint and records exact task identity", %{root: root, workspace: workspace} do
    configure_peer(root, "checkpoint")

    executor = fn "agent_workpad", args ->
      assert args["body"] =~ ~s("thread_id":"recovery-thread")
      %{"success" => true, "output" => "saved"}
    end

    assert :ok = AgentRunner.run(issue(), nil, max_turns: 1, tool_executor: executor, issue_state_fetcher: fn _ -> {:ok, [issue()]} end)
    state = WorkerRecovery.read!(WorkerRecovery.context(issue()))
    assert state["latest"]["workspace"] == workspace
    assert state["latest"]["thread_id"] == "recovery-thread"
    assert state["workpad"] =~ "Next: implement"
    assert state["latest"]["checkpoint_turn"] == 1
    turns = root |> Path.join("wire.jsonl") |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) |> Enum.filter(&(&1["method"] == "turn/start"))
    assert length(turns) == 2
  end

  test "refusing to checkpoint is an ordinary bounded failure, never an infinite checkpoint loop", %{root: root} do
    configure_peer(root, "ignore")

    assert_raise RuntimeError, ~r/checkpoint_not_saved/, fn ->
      AgentRunner.run(issue(), nil, max_turns: 1, issue_state_fetcher: fn _ -> {:ok, [issue()]} end)
    end

    state = WorkerRecovery.read!(WorkerRecovery.context(issue()))
    assert state["failures"] == 1
    refute state["active"]
  end

  test "handoff command is read-only and explains unavailable recovery", %{root: root, context: ctx, workspace: workspace} do
    start(ctx, workspace)
    WorkerRecovery.session!(ctx, %{thread_id: "resume-me", workspace: workspace})
    WorkerRecovery.finish!(ctx, :quota)
    # Supply a GitHub repo to the CLI's offline lookup, without making network requests.
    path = Workflow.workflow_file_path()
    body = File.read!(path) |> String.replace("tracker:\n", "tracker:\n  provider: {repo: owner/repo}\n")
    File.write!(path, body)
    :ok = WorkflowStore.force_reload()
    output = capture_io(fn -> Handoff.run(["GH-2", "--workflow", path]) end)
    assert Jason.decode!(output)["recovery"]["latest"]["thread_id"] == "resume-me"

    for args <- [[], ["bad"], ["GH-2", "--unknown"]] do
      assert_raise Mix.Error, fn -> Handoff.run(args) end
    end

    configure(root, recovery_enabled: false)
    assert_raise Mix.Error, ~r/not enabled/, fn -> Handoff.run(["GH-2"]) end
  end

  defp issue(state \\ "In progress") do
    %Issue{
      id: "2",
      identifier: "GH-2",
      title: "Recovery test",
      state: state,
      labels: ["symphony", "type:task"],
      dispatchable: true,
      native_ref: %{"repo" => "owner/repo"}
    }
  end

  defp start(ctx, workspace) do
    WorkerRecovery.start!(ctx)
    WorkerRecovery.workspace!(ctx, workspace)
  end

  defp configure(root, extra \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          tracker_kind: "memory",
          workspace_root: root,
          recovery_enabled: true,
          tracker_active_states: ["Ready", "In progress", "In review", "Integrating"],
          tracker_terminal_states: ["Done"]
        ],
        extra
      )
    )
  end

  defp configure_peer(root, mode) do
    fixture = Path.expand("test/fixtures/recovery_app_server.py")
    python = if match?({:win32, _}, :os.type()), do: ~s("#{System.find_executable("py")}" -3), else: "python3"
    command = ~s(#{python} "#{fixture}" "#{root}" #{mode}) |> String.replace("\\", "/")
    configure(root, codex_command: command)
  end

  defp git(workspace, args) do
    {_, 0} = System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true)
  end
end
