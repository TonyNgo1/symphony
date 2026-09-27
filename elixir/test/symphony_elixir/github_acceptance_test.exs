defmodule SymphonyElixir.GitHubAcceptanceTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GitHub.Acceptance
  @sha String.duplicate("a", 40)

  test "exactly one versioned contract with unique stable IDs is required" do
    criteria = criteria()
    body = Acceptance.render(criteria)
    assert {:ok, ^criteria} = Acceptance.parse("## Scope\nText\n" <> body <> "\n## Notes\nMore text")
    assert {:ok, ^criteria} = Acceptance.parse(String.replace(body, "\n", "\r\n"))

    for invalid <- [
          nil,
          "",
          "```symphony-acceptance\n{}\n```",
          body <> "\n" <> body,
          String.replace(body, "\"version\": 1", "\"version\": 2"),
          String.replace(body, "\"version\": 1", "\"extra\": true, \"version\": 1")
        ] do
      assert {:error, :github_invalid_acceptance_contract} = Acceptance.parse(invalid)
    end

    for invalid <- [
          nil,
          [],
          [nil],
          [hd(criteria), hd(criteria)],
          [Map.put(hd(criteria), "id", "A0")],
          [Map.put(hd(criteria), "description", " ")],
          [Map.put(hd(criteria), "extra", true)],
          [Map.put(hd(criteria), "covers", "R1")],
          [Map.put(hd(criteria), "covers", [])],
          [Map.put(hd(criteria), "covers", ["R1", "R1"])],
          [Map.put(hd(criteria), "validation", %{"kind" => "unknown"})]
        ] do
      assert {:error, :github_invalid_acceptance_contract} = Acceptance.validate(invalid)
    end
  end

  test "fingerprint ignores order but binds descriptions, validation and scope coverage" do
    first = hd(criteria())
    second = %{first | "id" => "A2"}
    assert Acceptance.fingerprint([first, second]) == Acceptance.fingerprint([second, first])
    refute Acceptance.fingerprint([first]) == Acceptance.fingerprint([Map.put(first, "covers", ["R1"])])
    refute Acceptance.fingerprint([first]) == Acceptance.fingerprint([%{first | "description" => "New requirement"}])
  end

  test "every criterion needs exactly one passing entry at the expected commit" do
    get = fn _ -> flunk("review evidence must not cause a check lookup") end
    assert :ok = Acceptance.verify(criteria(), evidence(), @sha, get)
    two = criteria() ++ [Map.put(hd(criteria()), "id", "A2")]
    assert {:error, {:github_acceptance_coverage_mismatch, ["A1", "A2"]}} = Acceptance.verify(two, evidence(), @sha, get)
    assert :ok = Acceptance.verify(two, %{"acceptance" => [Map.put(entry(), "id", "A2"), entry()]}, @sha, get)
    assert {:error, :github_acceptance_evidence_required} = Acceptance.verify(criteria(), %{}, @sha, get)

    for entries <- [[], [nil], [entry(), entry()], [Map.put(entry(), "id", "A2")]] do
      assert {:error, {:github_acceptance_coverage_mismatch, ["A1"]}} = Acceptance.verify(criteria(), %{"acceptance" => entries}, @sha, get)
    end

    for change <- [%{"sha" => String.duplicate("b", 40)}, %{"result" => "failed"}, %{"result" => "not run"}, %{"details" => " "}] do
      assert {:error, {:github_invalid_acceptance_evidence, "A1"}} = Acceptance.verify(criteria(), %{"acceptance" => [Map.merge(entry(), change)]}, @sha, get)
    end
  end

  test "CI evidence is verified with GitHub, bound to commit, check name and publisher app" do
    criteria = [Map.put(hd(criteria()), "validation", %{"kind" => "github_check", "name" => "Gameplay", "app_id" => 42})]
    assert :ok = Acceptance.validate(criteria)
    evidence = %{"acceptance" => [Map.put(entry(), "check_run_id", 123)]}
    check = %{"name" => "Gameplay", "head_sha" => @sha, "status" => "completed", "conclusion" => "success", "app" => %{"id" => 42}}
    get = fn "/check-runs/123" -> {:ok, check} end
    assert :ok = Acceptance.verify(criteria, evidence, @sha, get)
    assert {:error, :github_acceptance_check_required} = Acceptance.verify(criteria, evidence(), @sha, get)

    for change <- [%{"head_sha" => "other"}, %{"status" => "in_progress"}, %{"conclusion" => "failure"}, %{"conclusion" => "skipped"}, %{"name" => "Other"}, %{"app" => %{"id" => 99}}] do
      assert {:error, :github_acceptance_check_not_successful} = Acceptance.verify(criteria, evidence, @sha, fn _ -> {:ok, Map.merge(check, change)} end)
    end

    assert {:error, :rate_limited} = Acceptance.verify(criteria, evidence, @sha, fn _ -> {:error, :rate_limited} end)
  end

  defp criteria, do: [%{"id" => "A1", "description" => "Does the expected thing", "validation" => %{"kind" => "review", "instructions" => "Run the test and inspect output"}}]
  defp entry, do: %{"id" => "A1", "sha" => @sha, "result" => "passed", "details" => "Executed test; expected behavior observed"}
  defp evidence, do: %{"acceptance" => [entry()]}
end
