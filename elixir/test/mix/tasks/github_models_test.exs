defmodule Mix.Tasks.Github.ModelsTest do
  use SymphonyElixir.TestSupport
  import ExUnit.CaptureIO
  alias Mix.Tasks.Github.Models
  alias SymphonyElixir.GitHub.Http

  defmodule FakeClient do
    def fetch_issues_by_ids(["GH-1"]), do: {:ok, [%{model: "small", reasoning_effort: "low"}]}
    def fetch_issues_by_ids(_), do: {:error, :missing_issue}

    def update_model_selection(identifier, values) do
      send(self(), {:selection, identifier, values})
      {:ok, values}
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :github_client_module)
    Application.put_env(:symphony_elixir, :github_client_module, FakeClient)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:symphony_elixir, :github_client_module, previous),
        else: Application.delete_env(:symphony_elixir, :github_client_module)
    end)

    :ok
  end

  test "planner command reads, assigns and clears selections without starting workers" do
    scheduler = Process.whereis(Orchestrator)
    output = capture_io(fn -> Models.run(["GH-1", "--workflow", Workflow.workflow_file_path()]) end)
    assert Jason.decode!(output) == %{"model" => "small", "reasoning_effort" => "low"}
    capture_io(fn -> Models.run(["GH-1", "--model", "large", "--effort", "high"]) end)
    assert_receive {:selection, "GH-1", %{model: "large", reasoning_effort: "high"}}
    capture_io(fn -> Models.run(["GH-1", "--clear-model", "--clear-effort"]) end)
    assert_receive {:selection, "GH-1", %{model: nil, reasoning_effort: nil}}
    assert Process.whereis(Orchestrator) == scheduler
  end

  test "planner command reports malformed arguments, conflicting flags and missing issues" do
    for args <- [[], ["GH-1", "GH-2"], ["GH-1", "--unknown"]] do
      assert_raise Mix.Error, fn -> Models.run(args) end
    end

    assert_raise Mix.Error, ~r/Choose a value/, fn -> Models.run(["GH-1", "--model", "small", "--clear-model"]) end
    assert_raise Mix.Error, ~r/missing_issue/, fn -> Models.run(["GH-99"]) end
  end

  test "planner command initializes HTTP when invoked without the application service" do
    :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, Http)

    on_exit(fn ->
      if pid = Process.whereis(Http), do: GenServer.stop(pid)
      Supervisor.restart_child(SymphonyElixir.Supervisor, Http)
    end)

    capture_io(fn -> Models.run(["GH-1"]) end)
    assert Http.stats().rest == 0
  end
end
