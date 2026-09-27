defmodule Mix.Tasks.Github.PlanTest do
  use ExUnit.Case
  import ExUnit.CaptureIO
  alias Mix.Tasks.Github.Plan

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "offline planner writes the same validated bundle without starting a scheduler", %{root: root} do
    example = Path.join(root, "plan.json")
    criterion = %{"id" => "A1", "description" => "Expected behavior", "covers" => ["R1"], "validation" => %{"kind" => "review", "instructions" => "Run the scenario"}}
    issue = %{"key" => "P", "kind" => "feature", "title" => "Feature", "objective" => "Deliver the behavior", "blocked_by" => [], "acceptance" => [criterion]}

    plan = %{
      "version" => 1,
      "repository" => "owner/repo",
      "project_number" => 1,
      "requirements" => [%{"id" => "R1", "description" => "Expected behavior"}],
      "issues" => [issue, Map.merge(issue, %{"key" => "C", "kind" => "task", "parent" => "P"})]
    }

    File.write!(example, Jason.encode!(plan))
    scheduler = Process.whereis(SymphonyElixir.Orchestrator)
    output = capture_io(fn -> Plan.run([example]) end)
    assert %{"issues" => [_, _]} = Jason.decode!(output)
    target = Path.join(root, "validated.json")
    Plan.run([example, "--output", target])
    assert Jason.decode!(File.read!(target)) == Jason.decode!(output)
    assert Process.whereis(SymphonyElixir.Orchestrator) == scheduler
  end

  test "bad arguments or plans never overwrite a previous validated output", %{root: root} do
    for args <- [[], ["one", "two"], ["one", "--typo"]] do
      assert_raise Mix.Error, ~r/Usage:/, fn -> Plan.run(args) end
    end

    source = Path.join(root, "plan.json")
    target = Path.join(root, "validated.json")
    File.write!(target, "previous valid output")
    assert_raise Mix.Error, ~r/Plan validation failed/, fn -> Plan.run([source, "--output", target]) end

    for content <- ["not JSON", "{}"] do
      File.write!(source, content)
      assert_raise Mix.Error, ~r/Plan validation failed/, fn -> Plan.run([source, "--output", target]) end
      assert File.read!(target) == "previous valid output"
    end
  end
end
