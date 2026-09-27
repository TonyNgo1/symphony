defmodule SymphonyElixir.GitHubLifecycleTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.Failure

  setup do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["Ready", "In progress", "In review", "Integrating"],
      tracker_terminal_states: ["Done"],
      max_concurrent_agents: 2,
      max_concurrent_agents_by_state: %{"Integrating" => 1},
      poll_interval_ms: 600_000
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    on_exit(fn -> :persistent_term.erase({Orchestrator, :dispatch_paused}) end)
    :ok
  end

  test "review and integration always end the previous worker, while Ready can enter implementation" do
    original = issue("Ready")

    for {state, result} <- [{"In progress", :continue}, {"In review", :done}, {"Integrating", :done}, {"Human Review", :done}, {"Done", :done}] do
      refreshed = %{original | state: state}
      assert {^result, ^refreshed} = AgentRunner.continue_with_issue_for_test(original, fn _ -> {:ok, [refreshed]} end)
    end

    original = issue("In review")
    refreshed = issue("In progress")
    assert {:done, ^refreshed} = AgentRunner.continue_with_issue_for_test(original, fn _ -> {:ok, [refreshed]} end)
    refreshed = %{original | dispatchable: false}
    assert {:done, ^refreshed} = AgentRunner.continue_with_issue_for_test(original, fn _ -> {:ok, [refreshed]} end)
  end

  test "quota errors in completed turns are failures, not twenty successful continuation turns" do
    for code <- ["usage_limit_exceeded", "usageLimitExceeded"] do
      assert {:error, :usage_limit_exceeded} =
               AppServer.completed_turn_result(%{
                 "params" => %{"turn" => %{"status" => "failed", "error" => %{"codexErrorInfo" => code}}}
               })

      assert Failure.usage_limit?({:response_error, %{"data" => %{"error" => %{"code" => code}}}})
    end

    failure = %{"params" => %{"turn" => %{"status" => "failed", "error" => %{"code" => "network_error"}}}}
    assert {:error, {:turn_failed, _}} = AppServer.completed_turn_result(failure)
    assert {:ok, :turn_completed} = AppServer.completed_turn_result(%{"params" => %{"turn" => %{"status" => "completed"}}})
    refute Failure.usage_limit?(%{"message" => "the source mentions usage_limit_exceeded"})
    refute Failure.usage_limit?(%{"code" => "rate_limit_exceeded"})
  end

  test "usage limit stops its worker, cancels retries and survives refresh and scheduler restart" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    pid = start_supervised!({Orchestrator, name: __MODULE__.Scheduler, task_supervisor: supervisor})

    {:ok, task} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    worker_monitor = Process.monitor(task)
    retry_token = make_ref()
    timer = Process.send_after(pid, {:retry_issue, "3", retry_token}, 60_000)

    :sys.replace_state(pid, fn state ->
      %{state | running: %{"2" => entry(task)}, claimed: MapSet.new(["2", "3"]), retry_attempts: %{"3" => %{attempt: 1, timer_ref: timer, retry_token: retry_token, due_at_ms: 0}}}
    end)

    send(pid, {:codex_worker_update, "2", %{reason: :usage_limit_exceeded}})
    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.dispatch_paused == :usage_limit_exceeded
    assert snapshot.running == []
    assert snapshot.retrying == []
    assert_receive {:DOWN, ^worker_monitor, :process, ^task, _}
    assert Process.read_timer(timer) == false
    send(pid, {:retry_issue, "3", retry_token})
    Orchestrator.request_refresh(__MODULE__.Scheduler)
    assert GenServer.call(pid, :snapshot).dispatch_paused == :usage_limit_exceeded
    refute Orchestrator.should_dispatch_issue_for_test(issue("Ready"), :sys.get_state(pid))
    stop_supervised!(Orchestrator)
    restarted = start_supervised!({Orchestrator, name: __MODULE__.Scheduler, task_supervisor: supervisor})
    assert GenServer.call(restarted, :snapshot).dispatch_paused == :usage_limit_exceeded
  end

  test "ordinary worker exits still schedule a backoff retry" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.RetryTasks})
    pid = start_supervised!({Orchestrator, name: __MODULE__.RetryScheduler, task_supervisor: supervisor})

    {:ok, task} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    state = :sys.replace_state(pid, fn state -> %{state | running: %{"2" => entry(task)}, claimed: MapSet.new(["2"])} end)
    send(pid, {:DOWN, state.running["2"].ref, :process, task, :network_failure})
    snapshot = GenServer.call(pid, :snapshot)
    assert is_nil(snapshot.dispatch_paused)
    assert [%{attempt: 1}] = snapshot.retrying
  end

  test "a streamed usage error stops the app-server turn immediately" do
    root = Path.join(System.tmp_dir!(), "symphony-quota-stream-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "GH-2")
    File.mkdir_p!(workspace)
    script = Path.join(root, "fake-codex.sh")

    File.write!(script, """
    while IFS= read -r line; do
      case "$line" in
        *'"id":1'*) printf '%s\\n' '{"id":1,"result":{}}' ;;
        *'"id":2'*) printf '%s\\n' '{"id":2,"result":{"thread":{"id":"quota-thread"}}}' ;;
        *'"id":3'*)
          printf '%s\\n' '{"id":3,"result":{"turn":{"id":"quota-turn"}}}'
          printf '%s\\n' '{"method":"error","params":{"error":{"codexErrorInfo":"usageLimitExceeded"},"willRetry":false}}'
          ;;
      esac
    done
    """)

    script = String.replace(script, "\\", "/")
    timeouts = [codex_read_timeout_ms: 2_000, codex_turn_timeout_ms: 2_000]
    opts = [tracker_kind: "memory", workspace_root: root, codex_command: "bash '#{script}'"] ++ timeouts
    write_workflow_file!(Workflow.workflow_file_path(), opts)
    on_exit(fn -> File.rm_rf(root) end)
    recipient = self()
    assert {:error, :usage_limit_exceeded} = AppServer.run(workspace, "quota test", issue("In progress"), on_message: fn message -> send(recipient, {:stream, message}) end)
    assert_receive {:stream, %{event: :turn_ended_with_error, reason: :usage_limit_exceeded}}
  end

  test "a completed workspace is reused without rerunning initial setup" do
    root = Path.join(System.tmp_dir!(), "symphony-persistent-#{System.unique_integer([:positive])}")
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", workspace_root: root)
    on_exit(fn -> File.rm_rf(root) end)
    assert {:ok, workspace} = Workspace.create_for_issue(issue("Ready"))
    refute File.exists?(workspace <> ".initializing")
    File.write!(Path.join(workspace, "uncommitted.txt"), "resumable work")
    assert {:ok, ^workspace} = Workspace.create_for_issue(issue("In progress"))
    assert File.read!(Path.join(workspace, "uncommitted.txt")) == "resumable work"
  end

  test "two issues maximum and only one integration at a time" do
    state = %Orchestrator.State{max_concurrent_agents: 2, running: %{}, claimed: MapSet.new()}
    assert Orchestrator.should_dispatch_issue_for_test(issue("Ready"), state)
    state = %{state | running: %{"1" => %{issue: %{issue("Integrating") | id: "1"}}}}
    refute Orchestrator.should_dispatch_issue_for_test(issue("Integrating"), state)
    assert Orchestrator.should_dispatch_issue_for_test(issue("In review"), state)
    state = %{state | running: Map.put(state.running, "3", %{issue: %{issue("Ready") | id: "3"}})}
    refute Orchestrator.should_dispatch_issue_for_test(issue("Ready"), state)
  end

  test "reconciliation stops an implementation worker when the issue moves to review" do
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.PhaseTasks})

    {:ok, task} =
      Task.Supervisor.start_child(supervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    state = %Orchestrator.State{
      task_supervisor: supervisor,
      running: %{"2" => entry(task)},
      claimed: MapSet.new(["2"]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }

    state = Orchestrator.reconcile_issue_states_for_test([issue("In review")], state)
    assert state.running == %{}
    refute Process.alive?(task)
  end

  test "terminal workspace retention preserves files and reopening reuses the workspace" do
    path = Workflow.workflow_file_path()
    File.write!(path, String.replace(File.read!(path), "workspace:\n", "workspace:\n  retain_terminal: true\n"))
    :ok = WorkflowStore.force_reload()
    assert Config.settings!().workspace.retain_terminal
    test_root = Path.join(System.tmp_dir!(), "symphony-retain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(test_root)
    File.write!(Path.join(test_root, "uncommitted.txt"), "keep")
    on_exit(fn -> File.rm_rf(test_root) end)
    state = %Orchestrator.State{}
    Orchestrator.handle_retry_issue_lookup_for_test(issue("Done"), state, "2", 1, %{workspace_path: test_root})
    assert File.read!(Path.join(test_root, "uncommitted.txt")) == "keep"
  end

  defp issue(state), do: %Issue{id: "2", identifier: "GH-2", title: "Bounded task", state: state, dispatchable: true, labels: ["symphony", "type:task"], native_ref: %{"repo" => "octo/repo"}}
  defp entry(task), do: %{pid: task, ref: Process.monitor(task), identifier: "GH-2", issue: issue("In progress"), started_at: DateTime.utc_now(), session_id: nil, retry_attempt: 0}
end
