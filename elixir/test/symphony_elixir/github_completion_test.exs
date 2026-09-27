defmodule SymphonyElixir.GitHubCompletionTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.GitHub.{Acceptance, AgentTool, Client, Completion}

  @source String.duplicate("a", 40)
  @target String.duplicate("b", 40)
  @old String.duplicate("c", 40)
  @states ["Backlog", "Ready", "In progress", "In review", "Integrating", "Human Review", "Done"]

  test "review requires commit-bound passing evidence before any project write" do
    {store, opts} = fixture()

    for evidence <- [nil, %{}, evidence(@old), evidence(@source, "failed"), evidence(@source, "not run")] do
      assert {:error, :github_invalid_validation_evidence} = transition("Integrating", opts, evidence)
      assert Agent.get(store, & &1.state) == "In review"
    end
  end

  test "corrupt review records and malformed remote branch heads are rejected" do
    for body <- ["Review: invalid", "Review: []", "Review: null", "Review: {}\nReview: {}"] do
      assert is_nil(Completion.read_record(body))
    end

    issue = %Issue{id: "2", labels: ["type:task"]}

    for payload <- [%{}, %{"object" => %{"type" => "tag", "sha" => @source}}, %{"object" => %{"type" => "commit", "sha" => "bad"}}] do
      assert {:error, :github_invalid_branch_head} = Completion.review(issue, evidence(@source), fn _ -> {:ok, payload} end)
    end
  end

  test "integration cannot target a missing or foreign parent" do
    get = fn _ -> {:ok, %{"object" => %{"type" => "commit", "sha" => @source}}} end
    record = evidence(@source) |> Map.put("sha", @source) |> Map.put("acceptance_hash", Acceptance.fingerprint(criteria()))

    for parent <- [nil, %{"in_project" => true, "number" => 1, "repo" => "other/repo", "labels" => ["type:feature"]}] do
      issue = %Issue{id: "2", description: Acceptance.render(criteria()), labels: ["type:task"], native_ref: %{"repo" => "octo/repo", "parent" => parent}}
      assert {:error, :github_invalid_integration_target} = Completion.finish(issue, evidence(@target), record, get)
    end
  end

  test "review record survives worker handoffs and workpad replacement cannot forge it" do
    {store, opts} = fixture()
    args = %{"issue_identifier" => "GH-2", "status" => "Integrating", "evidence" => evidence(@source)}
    assert AgentTool.execute("set_project_status", args, opts)["success"]
    assert {:ok, pad} = Client.workpad("GH-2", nil, opts)
    assert Completion.read_record(pad["body"])["sha"] == @source
    forged = "## Agent Workpad\nCurrent: integrating\nReview: {\"sha\":\"forged\"}"
    assert {:ok, _} = Client.workpad("GH-2", forged, opts)
    assert {:ok, pad} = Client.workpad("GH-2", nil, opts)
    assert Completion.read_record(pad["body"])["sha"] == @source
    assert pad["body"] =~ "Current: integrating"
    assert Agent.get(store, & &1.state) == "Integrating"
  end

  test "Done verifies child ancestry in the native parent branch and exact validated target head" do
    {store, opts} = fixture()
    assert {:ok, _} = transition("Integrating", opts, evidence(@source))
    integrating = with_role(opts, "Integrating")
    assert {:ok, _} = transition("Done", integrating, evidence(@target))
    assert {:ok, _} = transition("Done", integrating, evidence(@target))
    assert Agent.get(store, & &1.state) == "Done"
    paths = Agent.get(store, & &1.paths)
    assert "/repos/octo/repo/git/ref/heads/feature/GH-1" in paths
    refute "/repos/octo/repo/git/ref/heads/main" in paths
  end

  test "moved source, moved target, missing review, divergent merge and API errors cannot mark Done" do
    for change <- [
          %{source: @old},
          %{target: @old},
          %{comment: nil},
          %{ancestor: @old},
          %{read_error: true}
        ] do
      {store, opts} = fixture()
      assert {:ok, _} = transition("Integrating", opts, evidence(@source))
      Agent.update(store, &Map.merge(&1, change))
      assert {:error, _} = transition("Done", with_role(opts, "Integrating"), evidence(@target))
      assert Agent.get(store, & &1.state) == "Integrating"
    end
  end

  test "failed or absent integration validation cannot mark Done" do
    {store, opts} = fixture()
    assert {:ok, _} = transition("Integrating", opts, evidence(@source))

    for result <- [nil, %{}, evidence(@target, "failed"), evidence(@source)] do
      assert {:error, _} = transition("Done", with_role(opts, "Integrating"), result)
      assert Agent.get(store, & &1.state) == "Integrating"
    end
  end

  test "feature approval persists across the human pause and completion verifies main" do
    {store, opts} = fixture(feature: true)
    assert {:ok, _} = transition("Human Review", opts, evidence(@source))
    assert {:error, :github_human_review_pause} = transition("Integrating", opts, evidence(@source))
    # Simulate the human's board action, outside the worker status tool.
    Agent.update(store, &%{&1 | state: "Integrating"})
    assert {:ok, _} = transition("Done", with_role(opts, "Integrating"), evidence(@target))
    assert "/repos/octo/repo/git/ref/heads/main" in Agent.get(store, & &1.paths)
  end

  test "bug review requires a named regression that failed on a different commit and now passes" do
    {store, opts} = fixture(bug: true)
    assert {:error, :github_regression_evidence_required} = transition("Integrating", opts, evidence(@source))
    regression = %{"test" => "autotarget excludes friendlies", "command" => "run targeting test", "before_sha" => @old, "before" => "failed", "after" => "passed"}

    for invalid <- [Map.put(regression, "before", "passed"), Map.put(regression, "before_sha", @source), Map.put(regression, "test", "")] do
      assert {:error, :github_regression_evidence_required} = transition("Integrating", opts, Map.put(evidence(@source), "regression", invalid))
    end

    assert {:ok, _} = transition("Integrating", opts, Map.put(evidence(@source), "regression", regression))
    assert Completion.read_record(Agent.get(store, & &1.comment))["regression"] == regression
  end

  test "return to implementation invalidates approval and a manual jump cannot reuse it" do
    {store, opts} = fixture()
    assert {:ok, _} = transition("Integrating", opts, evidence(@source))
    integrating = with_role(opts, "Integrating")
    assert {:ok, _} = transition("In progress", integrating, nil)
    assert is_nil(Completion.read_record(Agent.get(store, & &1.comment)))
    forged = %{"sha" => @source, "validation" => evidence(@source)["validation"]}
    assert {:ok, _} = Client.workpad("GH-2", "## Agent Workpad\nCurrent: resumed\nReview: " <> Jason.encode!(forged), opts)
    assert is_nil(Completion.read_record(Agent.get(store, & &1.comment)))
    Agent.update(store, &%{&1 | state: "Integrating"})
    assert {:error, _} = transition("Done", integrating, evidence(@target))
  end

  test "a question-only human pause does not create a feature approval" do
    {store, opts} = fixture(feature: true)
    assert {:ok, _} = Client.update_project_status("GH-2", "Human Review", opts)
    assert is_nil(Agent.get(store, & &1.comment))
    Agent.update(store, &%{&1 | state: "Integrating"})
    assert {:error, _} = transition("Done", with_role(opts, "Integrating"), evidence(@target))
    assert Agent.get(store, & &1.state) == "Integrating"
  end

  test "review storage failure does not advance the issue or exceed the workpad limit" do
    {store, opts} = fixture()
    Agent.update(store, &%{&1 | comment: "## Agent Workpad\n" <> Enum.map_join(1..39, "\n", fn _ -> "context" end)})
    assert {:error, :github_invalid_workpad} = transition("Integrating", opts, evidence(@source))
    assert Agent.get(store, & &1.state) == "In review"
  end

  test "partial acceptance, duplicate IDs, stale checks and changed criteria cannot complete" do
    {store, opts} = fixture()
    valid = evidence(@source)

    for entries <- [[], [hd(valid["acceptance"]), hd(valid["acceptance"])], [%{"id" => "A1", "sha" => @old, "result" => "passed", "details" => "checked"}]] do
      assert {:error, _} = transition("Integrating", opts, Map.put(valid, "acceptance", entries))
      assert Agent.get(store, & &1.state) == "In review"
    end

    assert {:ok, _} = transition("Integrating", opts, valid)
    changed = [Map.put(hd(criteria()), "description", "Changed scope")]
    Agent.update(store, &Map.put(&1, :body, Acceptance.render(changed)))
    assert {:error, :github_review_or_ancestry_mismatch} = transition("Done", with_role(opts, "Integrating"), evidence(@target))
    assert Agent.get(store, & &1.state) == "Integrating"
  end

  test "fresh issue body overrides cached project content and legacy approval fails closed" do
    {store, opts} = fixture()
    Agent.update(store, &Map.put(&1, :body, "Old unstructured acceptance"))
    assert {:error, :github_invalid_acceptance_contract} = transition("Integrating", opts, evidence(@source))
    assert Agent.get(store, & &1.state) == "In review"
  end

  test "asset approval resumes through fresh review and verifies recursive tree parameters before project writes" do
    {store, opts} = fixture()
    path = "reviews/impact/v1/manifest.json"

    criterion = %{
      "id" => "A1",
      "description" => "Approved sound",
      "validation" => %{
        "kind" => "human_asset",
        "manifest" => path,
        "reviewers" => ["human"],
        "instructions" => "Audition the gameplay capture"
      }
    }

    files =
      Enum.map(
        [{"assets/hit.wav", "asset"}, {"reviews/impact/v1/hit.wav", "preview"}, {"reviews/impact/v1/index.html", "review_page"}],
        fn {file, role} -> %{"path" => file, "role" => role, "blob" => @old} end
      )

    bytes = Jason.encode!(%{"version" => 1, "asset_id" => "impact", "files" => files})
    hash = :crypto.hash(:sha, "blob #{byte_size(bytes)}\0" <> bytes) |> Base.encode16(case: :lower)
    approval = %{"version" => 1, "decision" => "approved", "criterion" => criterion, "manifest" => path, "manifest_blob" => hash}

    comment = %{
      "user" => %{"type" => "User", "login" => "human"},
      "issue_url" => "https://api.github.com/repos/octo/repo/issues/2",
      "body" => "## Asset Approval\n```symphony-asset-approval\n" <> Jason.encode!(approval) <> "\n```"
    }

    Agent.update(store, &Map.put(&1, :body, Acceptance.render([criterion])))
    request = Keyword.fetch!(opts, :request_fun)

    wrapped = fn method, url, params, body, config ->
      cond do
        url == "/repos/octo/repo/issues/comments/987" ->
          ok(comment)

        String.starts_with?(url, "/repos/octo/repo/git/trees/") ->
          assert params == %{"recursive" => "1"}
          tree = Enum.map(files, &%{"path" => &1["path"], "sha" => &1["blob"], "type" => "blob", "mode" => "100644"})
          ok(%{"truncated" => false, "tree" => tree ++ [%{"path" => path, "sha" => hash, "type" => "blob", "mode" => "100644"}]})

        url == "/repos/octo/repo/git/blobs/#{hash}" ->
          ok(%{"encoding" => "base64", "content" => Base.encode64(bytes)})

        true ->
          request.(method, url, params, body, config)
      end
    end

    opts = Keyword.put(opts, :request_fun, wrapped)
    assert {:error, :github_asset_approval_required_or_stale} = transition("Integrating", opts, evidence(@source))
    assert Agent.get(store, & &1.state) == "In review"
    assert {:ok, _} = Client.update_project_status("GH-2", "Human Review", opts)
    assert is_nil(Completion.read_record(Agent.get(store, & &1.comment)))
    assert {:error, :github_human_review_pause} = transition("Integrating", opts, evidence(@source))
    # The human posts their separate comment and releases to fresh technical review.
    Agent.update(store, &%{&1 | state: "In review"})
    approved = fn sha -> update_in(evidence(sha), ["acceptance"], fn [entry] -> [Map.put(entry, "approval_comment_id", 987)] end) end
    assert {:ok, _} = transition("Integrating", opts, approved.(@source))
    assert {:ok, _} = transition("Done", with_role(opts, "Integrating"), approved.(@target))
    assert Agent.get(store, & &1.state) == "Done"
  end

  defp criteria, do: [%{"id" => "A1", "description" => "Observable behavior", "validation" => %{"kind" => "review", "instructions" => "Run the scenario"}}]

  defp evidence(sha, result \\ "passed"),
    do: %{
      "validation" => %{"sha" => sha, "command" => "run combined validation", "result" => result},
      "acceptance" => [%{"id" => "A1", "sha" => sha, "result" => result, "details" => "Ran the scenario and observed the expected behavior"}]
    }

  defp transition(status, opts, evidence), do: Client.update_project_status("GH-2", status, Keyword.put(opts, :evidence, evidence))
  defp with_role(opts, role), do: Keyword.update!(opts, :issue, &%{&1 | state: role})

  defp fixture(flags \\ []) do
    feature = Keyword.get(flags, :feature, false)
    labels = [if(feature, do: "type:feature", else: "type:task"), "symphony"] ++ if(Keyword.get(flags, :bug, false), do: ["bug"], else: [])
    initial = Map.merge(%{state: "In review", comment: nil, paths: [], read_error: false}, %{source: @source, target: @target, ancestor: @source})
    {:ok, store} = Agent.start_link(fn -> initial end)
    on_exit(fn -> if Process.alive?(store), do: Agent.stop(store) end)
    tracker = %{provider: %{"repo" => "octo/repo", "token" => "test", "project_number" => 1}}

    request = fn method, path, _params, body, _config ->
      Agent.update(store, &%{&1 | paths: [path | &1.paths]})
      state = Agent.get(store, & &1)
      response(method, path, body, state, store, labels, feature)
    end

    issue = %Issue{id: "2", identifier: "GH-2", state: "In review", labels: labels}
    {store, [tracker_settings: tracker, request_fun: request, issue: issue]}
  end

  defp response(method, path, body, _state, store, _labels, _feature) when method in ["POST", "PATCH"] do
    if String.ends_with?(path, "/items/102") do
      Agent.update(store, &%{&1 | state: hd(body["fields"])["value"]})
    else
      Agent.update(store, &%{&1 | comment: body["body"]})
    end

    ok(%{})
  end

  defp response("GET", "/repos/octo/repo/issues/2", _body, state, _store, _labels, _feature),
    do: ok(%{"body" => Map.get(state, :body, Acceptance.render(criteria()))})

  defp response("GET", path, _body, state, _store, labels, feature) do
    cond do
      String.ends_with?(path, "/comments") ->
        comments_response(state.comment)

      String.ends_with?(path, "/fields") ->
        ok([%{"id" => 10, "name" => "Status", "data_type" => "single_select", "options" => Enum.map(@states, &%{"id" => &1, "name" => &1})}])

      String.ends_with?(path, "/items") ->
        ok([item(1, "In progress", ["type:feature"]), item(2, state.state, labels), item(3, "Done", ["type:task"])])

      String.ends_with?(path, "/dependencies/blocked_by") ->
        ok([])

      String.ends_with?(path, "/sub_issues") ->
        ok(if(feature, do: [raw(3, ["type:task"])], else: []))

      String.ends_with?(path, "/parent") ->
        ok(raw(1, ["type:feature"]))

      true ->
        git_response(path, state, feature)
    end
  end

  defp comments_response(nil), do: ok([])
  defp comments_response(body), do: ok([%{"id" => 77, "body" => body}])

  defp git_response(_path, %{read_error: true}, _feature), do: {:ok, %{status: 403, body: %{}}}

  defp git_response(path, state, feature) do
    if String.contains?(path, "/git/ref/heads/") do
      source = if feature, do: "feature/GH-2", else: "task/GH-2"
      sha = if String.ends_with?(path, source), do: state.source, else: state.target
      ok(%{"object" => %{"type" => "commit", "sha" => sha}})
    else
      ok(%{"merge_base_commit" => %{"sha" => state.ancestor}})
    end
  end

  defp item(number, state, labels), do: %{"id" => number + 100, "content_type" => "Issue", "content" => raw(number, labels), "fields" => [%{"id" => 10, "value" => state}]}
  defp raw(number, labels), do: %{"number" => number, "labels" => labels, "state" => "open", "repository_url" => "https://api.github.com/repos/octo/repo"}
  defp ok(body), do: {:ok, %{status: 200, body: body}}
end
