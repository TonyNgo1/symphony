defmodule SymphonyElixir.StatusTransitionTest do
  use SymphonyElixir.TestSupport

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-handoff-#{System.unique_integer([:positive])}") |> String.replace("\\", "/")
    File.mkdir_p!(root)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      workspace_root: root,
      poll_interval_ms: 600_000,
      tracker_active_states: ["Ready", "In progress", "In review", "Integrating"],
      tracker_terminal_states: ["Done"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
    supervisor = start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    scheduler = start_supervised!({Orchestrator, name: __MODULE__.Scheduler, task_supervisor: supervisor})
    # Wait for the initial empty poll to finish before installing a controlled worker.
    await_poll!(scheduler)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, supervisor: supervisor, scheduler: scheduler}
  end

  for {source, target} <- [{"In progress", "In review"}, {"In review", "Integrating"}, {"In review", "Human Review"}, {"Integrating", "Done"}] do
    @source source
    @target target
    test "#{source} -> #{target} delivers the receipt before reconciliation can stop the worker", context do
      %{root: root, supervisor: supervisor, scheduler: scheduler} = context
      fixture = Path.expand("test/fixtures/status_transition_app_server.py")
      python = if match?({:win32, _}, :os.type()), do: ~s("#{System.find_executable("py")}" -3), else: "python3"
      command = ~s(#{python} "#{fixture}" "#{root}" "#{@target}") |> String.replace("\\", "/")

      write_workflow_file!(Workflow.workflow_file_path(),
        tracker_kind: "memory",
        workspace_root: root,
        poll_interval_ms: 600_000,
        tracker_active_states: ["Ready", "In progress", "In review", "Integrating"],
        tracker_terminal_states: ["Done"],
        codex_command: command
      )

      original = issue(@source)
      changed = %{original | state: @target}
      parent = self()

      executor = fn "set_project_status", _arguments ->
        send(parent, {:write_visible, self()})

        receive do
          :finish_tool -> %{"success" => true, "output" => "status written"}
        end
      end

      task =
        worker(supervisor, scheduler, original, fn ->
          AgentRunner.run(original, scheduler, tool_executor: executor, issue_state_fetcher: fn _ -> {:ok, [changed]} end)
        end)

      monitor = Process.monitor(task)
      assert_receive {:write_visible, ^task}, 10_000

      # The remote write is visible, but its readback/response is still in flight.
      reconcile(scheduler, changed)
      assert Process.alive?(task)
      refute Orchestrator.should_dispatch_issue_for_test(changed, :sys.get_state(scheduler))
      send(task, :finish_tool)
      await_file!(Path.join(root, "receipt.json"))
      assert %{"result" => %{"success" => true}} = root |> Path.join("receipt.json") |> File.read!() |> Jason.decode!()

      # Sending bytes alone must not release the claim; wait for peer completion.
      reconcile(scheduler, changed)
      assert Process.alive?(task)
      File.write!(Path.join(root, "finish-turn"), "")
      assert_receive {:DOWN, ^monitor, :process, ^task, :normal}, 10_000
      refute Map.has_key?(:sys.get_state(scheduler).running, original.id)
    end
  end

  test "a stalled handoff has a bounded lifetime and an old timer cannot kill its replacement", context do
    %{supervisor: supervisor, scheduler: scheduler} = context
    parent = self()

    task =
      worker(supervisor, scheduler, issue("In progress"), fn ->
        :ok = GenServer.call(scheduler, {:prepare_status_transition, "2", "In review"})
        send(parent, :prepared)
        receive do: (:finish -> :ok)
      end)

    monitor = Process.monitor(task)
    assert_receive :prepared
    guard = :sys.get_state(scheduler).running["2"].status_transition
    send(scheduler, {:status_transition_timeout, "2", guard.token})
    assert GenServer.call(scheduler, :snapshot).running == []
    assert_receive {:DOWN, ^monitor, :process, ^task, _}
    assert Process.read_timer(guard.timer) == false
    replacement = worker(supervisor, scheduler, issue("In review"), fn -> receive do: (:finish -> :ok) end)
    send(scheduler, {:status_transition_timeout, "2", guard.token})
    :sys.get_state(scheduler)
    assert Process.alive?(replacement)
  end

  test "a worker cannot register a handoff for another worker", %{scheduler: scheduler, supervisor: supervisor} do
    task = worker(supervisor, scheduler, issue("In progress"), fn -> receive do: (:finish -> :ok) end)
    assert {:error, :worker_not_running} = GenServer.call(scheduler, {:prepare_status_transition, "2", "In review"})
    refute Map.has_key?(:sys.get_state(scheduler).running["2"], :status_transition)
    assert Process.alive?(task)
  end

  test "quota exhaustion overrides a pending status handoff", %{scheduler: scheduler, supervisor: supervisor} do
    on_exit(fn -> :persistent_term.erase({Orchestrator, :dispatch_paused}) end)
    parent = self()

    task =
      worker(supervisor, scheduler, issue("In progress"), fn ->
        :ok = GenServer.call(scheduler, {:prepare_status_transition, "2", "In review"})
        send(parent, :prepared)
        receive do: (:finish -> :ok)
      end)

    assert_receive :prepared
    send(scheduler, {:usage_limit_exceeded, "2"})
    state = :sys.get_state(scheduler)
    assert state.running == %{}
    assert state.dispatch_paused == :usage_limit_exceeded
    refute Process.alive?(task)
  end

  test "unrelated status changes still stop a worker during its registered handoff", context do
    %{supervisor: supervisor, scheduler: scheduler} = context
    parent = self()

    task =
      worker(supervisor, scheduler, issue("In progress"), fn ->
        :ok = GenServer.call(scheduler, {:prepare_status_transition, "2", "In review"})
        send(parent, :prepared)
        receive do: (:finish -> :ok)
      end)

    assert_receive :prepared
    reconcile(scheduler, issue("Backlog"))
    refute Process.alive?(task)
  end

  defp worker(supervisor, scheduler, issue, fun) do
    {:ok, task} = Task.Supervisor.start_child(supervisor, fn -> receive do: (:run -> fun.()) end)

    :sys.replace_state(scheduler, fn state ->
      entry = %{
        pid: task,
        ref: Process.monitor(task),
        identifier: issue.identifier,
        issue: issue,
        started_at: DateTime.utc_now(),
        session_id: nil,
        retry_attempt: 0
      }

      %{state | running: %{issue.id => entry}, claimed: MapSet.new([issue.id])}
    end)

    send(task, :run)
    task
  end

  defp reconcile(scheduler, changed), do: :sys.replace_state(scheduler, &Orchestrator.reconcile_issue_states_for_test([changed], &1))

  defp await_poll!(scheduler, attempts \\ 100)
  defp await_poll!(_scheduler, 0), do: flunk("Initial scheduler poll did not finish")

  defp await_poll!(scheduler, attempts) do
    state = :sys.get_state(scheduler)

    minimum_due = System.monotonic_time(:millisecond) + 1_000

    unless is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms > minimum_due do
      Process.sleep(10)
      await_poll!(scheduler, attempts - 1)
    end
  end

  defp await_file!(path, attempts \\ 500)
  defp await_file!(_path, 0), do: flunk("Peer did not receive the tool response")

  defp await_file!(path, attempts) do
    unless File.exists?(path) do
      Process.sleep(10)
      await_file!(path, attempts - 1)
    end
  end

  defp issue(state), do: %Issue{id: "2", identifier: "GH-2", title: "Handoff", state: state, dispatchable: true, native_ref: %{"repo" => "octo/repo"}}
end
