defmodule SymphonyElixir.GitHubPlanTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GitHub.{Acceptance, Plan}

  test "compiled acceptance contract is enforced through review and integration" do
    alias SymphonyElixir.GitHub.Completion
    source = String.duplicate("a", 40)
    target = String.duplicate("b", 40)
    {:ok, %{"issues" => [parent, _]}} = Plan.compile(plan())
    issue = %SymphonyElixir.Tracker.Issue{id: "1", description: parent["body"], labels: ["type:feature"], native_ref: %{}}

    get = fn
      "/git/ref/heads/main" -> {:ok, %{"object" => %{"type" => "commit", "sha" => target}}}
      "/git/ref/heads/feature/GH-1" -> {:ok, %{"object" => %{"type" => "commit", "sha" => source}}}
      _ -> {:ok, %{"merge_base_commit" => %{"sha" => source}}}
    end

    evidence = fn sha ->
      %{
        "validation" => %{"sha" => sha, "command" => "Run the acceptance scenario", "result" => "passed"},
        "acceptance" => [%{"id" => "A1", "sha" => sha, "result" => "passed", "details" => "Expected behavior observed"}]
      }
    end

    assert {:error, :github_acceptance_evidence_required} = Completion.review(issue, Map.delete(evidence.(source), "acceptance"), get)
    assert {:ok, record} = Completion.review(issue, evidence.(source), get)
    assert :ok = Completion.finish(issue, evidence.(target), record, get)
    assert {:error, :github_acceptance_evidence_required} = Completion.finish(issue, Map.delete(evidence.(target), "acceptance"), record, get)
  end

  test "validated publication bodies share the completion contract and stay in Backlog" do
    assert {:ok, bundle} = Plan.compile(plan())
    assert bundle["repository"] == "TonyNgo1/ArtCom"
    assert Enum.all?(bundle["issues"], &(&1["status"] == "Backlog"))
    [parent, child] = bundle["issues"]
    assert child["parent"] == "P"
    assert child["labels"] == ["symphony", "type:task"]
    assert {:ok, [_]} = Acceptance.parse(parent["body"])
    assert {:ok, [_]} = Acceptance.parse(child["body"])
    bug = update_in(plan(), ["issues"], fn [p, c] -> [p, Map.put(c, "bug", true)] end)
    assert {:ok, %{"issues" => [_, %{"labels" => ["symphony", "type:task", "bug"]}]}} = Plan.compile(bug)
  end

  test "malformed, misspelled and duplicate metadata fail before rendering" do
    for invalid <- [
          nil,
          %{},
          Map.put(plan(), "version", 2),
          Map.put(plan(), "extra", 1),
          Map.put(plan(), "repository", "https://github.com/owner/repo"),
          Map.put(plan(), "project_number", 0),
          Map.put(plan(), "requirements", []),
          Map.put(plan(), "requirements", [nil]),
          Map.put(plan(), "issues", [nil]),
          Map.put(plan(), "issues", []),
          update_in(plan(), ["issues"], &(&1 ++ &1)),
          update_in(plan(), ["requirements"], &(&1 ++ &1)),
          child_change(%{"blocked_by" => ["P", "P"]}),
          child_change(%{"kind" => "typo"}),
          child_change(%{"typo" => true}),
          child_change(%{"acceptance" => []}),
          child_change(%{"objective" => "```symphony-acceptance\n{}\n```"})
        ] do
      assert {:error, :invalid_plan_schema} = Plan.compile(invalid)
    end
  end

  test "asset-generation plans require human acceptance and publish the routing label" do
    human = %{criterion("R1") | "validation" => %{"kind" => "human_asset", "manifest" => "reviews/art/v1/manifest.json", "reviewers" => ["TonyNgo1"], "instructions" => "Inspect in game"}}
    assert {:ok, %{"issues" => [_, child]}} = Plan.compile(child_change(%{"asset_generation" => true, "acceptance" => [human]}))
    assert "asset-generation" in child["labels"]
    assert {:ok, %{"issues" => [_, ordinary]}} = Plan.compile(child_change(%{"asset_generation" => false}))
    refute "asset-generation" in ordinary["labels"]

    for value <- [true, "true", nil, 1] do
      assert {:error, :invalid_plan_schema} = Plan.compile(child_change(%{"asset_generation" => value}))
    end
  end

  test "every agreed requirement and every criterion must participate in the coverage map" do
    assert {:error, {:invalid_plan_coverage, %{missing: ["R2"], unknown: []}}} =
             Plan.compile(update_in(plan(), ["requirements"], &(&1 ++ [%{"id" => "R2", "description" => "Forgotten behavior"}])))

    assert {:error, {:invalid_plan_coverage, %{unknown: ["unknown"]}}} =
             Plan.compile(child_change(%{"acceptance" => [criterion("unknown")]}))

    assert {:error, {:invalid_plan_coverage, _}} =
             Plan.compile(child_change(%{"acceptance" => [Map.delete(criterion("R1"), "covers")]}))
  end

  test "missing, foreign, nested or childless parents and invalid dependency references fail" do
    for change <- [%{"parent" => nil}, %{"parent" => "external/GH-1"}, %{"parent" => "C"}, %{"blocked_by" => ["missing"]}, %{"blocked_by" => ["C"]}] do
      assert {:error, {:invalid_plan_relationships, _}} = Plan.compile(child_change(change))
    end

    assert {:error, {:invalid_plan_relationships, _}} = Plan.compile(update_in(plan(), ["issues"], fn [p, c] -> [Map.put(p, "parent", "C"), c] end))
    assert {:error, {:invalid_plan_relationships, "P"}} = Plan.compile(update_in(plan(), ["issues"], &Enum.take(&1, 1)))
  end

  test "detects plain cycles and lifecycle deadlocks while permitting parent bootstrap" do
    # Child waiting for its parent's Done can never finish, despite an acyclic explicit DAG.
    assert {:error, {:plan_dependency_deadlock, _}} = Plan.compile(child_change(%{"blocked_by" => ["P"]}))
    assert {:error, {:plan_dependency_deadlock, _}} = Plan.compile(update_in(plan(), ["issues"], fn [p, c] -> [Map.put(p, "blocked_by", ["C"]), c] end))
    [p, c] = plan()["issues"]
    d = %{c | "key" => "D", "blocked_by" => ["C"]}
    assert {:ok, _} = Plan.compile(%{plan() | "issues" => [p, c, d]})
    assert {:error, {:plan_dependency_deadlock, _}} = Plan.compile(%{plan() | "issues" => [p, %{c | "blocked_by" => ["D"]}, d]})
    q = %{p | "key" => "Q", "blocked_by" => ["P"]}
    e = %{c | "key" => "E", "parent" => "Q"}
    assert {:ok, _} = Plan.compile(%{plan() | "issues" => [p, c, q, e]})
    # P cannot complete C while C waits for Q, whose bootstrap waits for P.
    assert {:error, {:plan_dependency_deadlock, _}} = Plan.compile(%{plan() | "issues" => [p, %{c | "blocked_by" => ["Q"]}, q, e]})
  end

  defp plan do
    %{
      "version" => 1,
      "repository" => "TonyNgo1/ArtCom",
      "project_number" => 1,
      "requirements" => [%{"id" => "R1", "description" => "Complete agreed scope"}],
      "issues" => [issue("P", "feature"), Map.put(issue("C", "task"), "parent", "P")]
    }
  end

  defp issue(key, kind), do: %{"key" => key, "kind" => kind, "title" => key, "objective" => "Deliver the behavior", "blocked_by" => [], "acceptance" => [criterion("R1")]}
  defp criterion(req), do: %{"id" => "A1", "description" => "Observable result", "covers" => [req], "validation" => %{"kind" => "review", "instructions" => "Run the acceptance scenario"}}
  defp child_change(change), do: update_in(plan(), ["issues"], fn [p, c] -> [p, Map.merge(c, change)] end)
end
