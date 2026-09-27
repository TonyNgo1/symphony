defmodule SymphonyElixir.ProjectAssignmentTest do
  use SymphonyElixir.TestSupport

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-project-#{System.unique_integer([:positive])}") |> String.replace("\\", "/")
    File.mkdir_p!(root)
    fixture = Path.expand("test/fixtures/model_app_server.py")
    python = if match?({:win32, _}, :os.type()), do: ~s("#{System.find_executable("py")}" -3), else: "python3"
    command = ~s(#{python} "#{fixture}" "#{root}") |> String.replace("\\", "/")
    config = [tracker_kind: "memory", workspace_root: root, codex_command: command, codex_project_id: "symphony-project"]
    write_workflow_file!(Workflow.workflow_file_path(), config)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, config: config}
  end

  test "every worker phase and replacement gets the project while retaining its workspace", %{root: root} do
    workspace = Path.join(root, "GH-1")
    File.mkdir_p!(workspace)

    for state <- ["Ready", "In progress", "In review", "Integrating", "In progress"] do
      issue = %Issue{id: "1", identifier: "GH-1", state: state}
      assert {:ok, _} = AppServer.run(workspace, "no-op", issue)
    end

    starts = for %{"method" => "thread/start", "params" => params} <- requests(root), do: params
    assert length(starts) == 5
    assert Enum.all?(starts, &(&1["projectId"] == "symphony-project" and &1["cwd"] == Path.expand(workspace)))
  end

  test "reload affects new sessions only and an omitted project preserves default behavior", %{root: root, config: config} do
    workspace = Path.join(root, "GH-1")
    File.mkdir_p!(workspace)
    assert {:ok, session} = AppServer.start_session(workspace)

    try do
      write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(config, :codex_project_id, nil))
      assert {:ok, _} = AppServer.run_turn(session, "no-op", %Issue{})
      assert {:ok, _} = AppServer.run(workspace, "no-op", %Issue{})
    after
      AppServer.stop_session(session)
    end

    starts = for %{"method" => "thread/start", "params" => params} <- requests(root), do: params
    assert Enum.count(starts, &(&1["projectId"] == "symphony-project")) == 1
    assert Enum.count(starts, &(not Map.has_key?(&1, "projectId"))) == 1
    refute Enum.any?(requests(root), &(&1["method"] == "thread/metadata/update"))
  end

  test "missing or incorrect server confirmation prevents any agent turn", %{root: root, config: config} do
    workspace = Path.join(root, "GH-1")
    File.mkdir_p!(workspace)

    for {flag, actual} <- [{"--wrong-project", "wrong-project"}, {"--missing-project", nil}] do
      updated = Keyword.put(config, :codex_command, config[:codex_command] <> " " <> flag)
      write_workflow_file!(Workflow.workflow_file_path(), updated)
      assert {:error, {:project_assignment_mismatch, "symphony-project", ^actual}} = AppServer.run(workspace, "no-op", %Issue{})
    end

    refute Enum.any?(requests(root), &(&1["method"] == "turn/start"))
  end

  test "invalid project configuration is rejected", %{config: config} do
    for project <- ["", "   ", 123] do
      write_workflow_file!(Workflow.workflow_file_path(), Keyword.put(config, :codex_project_id, project))
      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "codex.project_id"
    end
  end

  defp requests(root) do
    Path.wildcard(Path.join(root, "*.jsonl"))
    |> Enum.flat_map(fn file -> file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1) end)
  end
end
