defmodule SymphonyElixir.GitHubAssetReviewTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GitHub.{Acceptance, AssetReview, Completion, Plan}
  alias SymphonyElixir.Tracker.Issue

  @source String.duplicate("a", 40)
  @target String.duplicate("b", 40)
  @blob String.duplicate("c", 40)
  @path "reviews/impact/v1/manifest.json"

  test "planning accepts a human asset policy and binds every policy field" do
    criterion = criterion()
    assert :ok = Acceptance.validate([criterion])

    plan = %{
      "version" => 1,
      "repository" => "owner/repo",
      "project_number" => 1,
      "requirements" => [%{"id" => "R1", "description" => "Approved impact"}],
      "issues" => [
        %{"key" => "P", "kind" => "feature", "title" => "Feature", "objective" => "Integrate", "blocked_by" => [], "acceptance" => [criterion]},
        %{"key" => "C", "kind" => "task", "parent" => "P", "title" => "Impact", "objective" => "Audition", "blocked_by" => [], "acceptance" => [criterion]}
      ]
    }

    assert {:ok, %{"issues" => [_, child]}} = Plan.compile(plan)
    assert {:ok, [^criterion]} = Acceptance.parse(child["body"])

    for change <- [%{"manifest" => "reviews/new/manifest.json"}, %{"reviewers" => ["other"]}, %{"instructions" => "Other scenario"}] do
      updated = Map.update!(criterion, "validation", &Map.merge(&1, change))
      refute Acceptance.fingerprint([criterion]) == Acceptance.fingerprint([updated])
    end

    for policy <-
          [nil, %{}, Map.put(criterion["validation"], "extra", true)] ++
            Enum.map([nil, [], ["human", "HUMAN"], ["a/b"], [nil]], &Map.put(criterion["validation"], "reviewers", &1)) ++
            Enum.map([nil, "../secret", "/absolute", "a//b", "a/./b", "a/.git/config", "a\\b", "a?ref=main"], &Map.put(criterion["validation"], "manifest", &1)) do
      refute AssetReview.policy?(policy)
      assert {:error, _} = Acceptance.validate([%{criterion | "validation" => policy}])
    end
  end

  test "review and integration independently verify the same human-approved blobs" do
    fixture = fixture()
    get = getter(fixture)
    issue = issue()
    assert {:ok, record} = Completion.review(issue, evidence(@source), get)
    assert :ok = Completion.finish(issue, evidence(@target), record, get)
    # A merge conflict resolution changes the runtime file while preserving ancestry.
    modified = update_in(fixture, [:tree, "tree"], fn [first | rest] -> [%{first | "sha" => @target} | rest] end)
    changed_target = fn path -> if path == "/git/trees/#{@target}?recursive=1", do: {:ok, modified.tree}, else: get.(path) end
    assert {:error, :github_asset_manifest_mismatch} = Completion.finish(issue, evidence(@target), record, changed_target)
  end

  test "approval needs a human on the planned allowlist and the owning issue" do
    fixture = fixture()

    for change <- [
          %{"user" => %{"type" => "Bot", "login" => "human"}},
          %{"user" => %{"type" => "User", "login" => "other"}},
          %{"user" => nil},
          %{"issue_url" => "https://api.github.com/repos/owner/repo/issues/22"},
          %{"body" => "## Agent Workpad\n" <> fixture.comment["body"]},
          %{"body" => "looks good"},
          %{"body" => "## Asset Approval\n```symphony-asset-approval\ninvalid\n```"}
        ] do
      assert {:error, _} = verify(%{fixture | comment: Map.merge(fixture.comment, change)})
    end

    assert :ok = verify(put_in(fixture, [:comment, "user", "login"], "HUMAN"))
    assert {:error, _} = Acceptance.verify([criterion()], evidence(@source), @source, getter(fixture))

    for id <- [nil, 0, "7", -1] do
      invalid = update_in(evidence(@source), ["acceptance"], fn [entry] -> [Map.put(entry, "approval_comment_id", id)] end)
      assert {:error, _} = Acceptance.verify([criterion()], invalid, @source, getter(fixture), issue_id: "2")
    end
  end

  test "approval binds exact criterion and manifest, and edited or withdrawn comments fail closed" do
    fixture = fixture()

    for change <- [
          %{"decision" => "rejected"},
          %{"version" => 2},
          %{"criterion" => %{criterion() | "description" => "Other scope"}},
          %{"manifest" => "other/manifest.json"},
          %{"manifest_blob" => @target},
          %{"manifest_blob" => "bad"},
          %{"extra" => true}
        ] do
      assert {:error, _} = verify(%{fixture | comment: comment(Map.merge(fixture.approval, change))})
    end

    get = fn "/issues/comments/7" -> {:error, :not_found} end
    assert {:error, :not_found} = Acceptance.verify([criterion()], evidence(@source), @source, get, issue_id: "2")
  end

  test "truncated trees, missing manifests, corrupted blobs and GitHub errors never pass" do
    fixture = fixture()

    for tree <- [%{"tree" => fixture.tree["tree"], "truncated" => true}, %{"tree" => [], "truncated" => false}, %{}] do
      assert {:error, _} = verify(%{fixture | tree: tree})
    end

    for content <- [%{"encoding" => "none", "content" => ""}, %{"encoding" => "base64", "content" => "%%%"}, %{"encoding" => "base64", "content" => Base.encode64("changed")}] do
      assert {:error, _} = verify(%{fixture | content: content})
    end

    for bytes <- ["invalid JSON", "null", "{}"] do
      assert {:error, _} = verify(fixture_bytes(bytes))
    end

    get = getter(fixture)

    for failing <- ["/git/trees/#{@source}?recursive=1", "/git/blobs/#{fixture.approval["manifest_blob"]}"] do
      assert {:error, :rate_limited} = Acceptance.verify([criterion()], evidence(@source), @source, fn path -> if path == failing, do: {:error, :rate_limited}, else: get.(path) end, issue_id: "2")
    end
  end

  test "manifest requires distinct safe regular files, assets, previews, page and import settings" do
    fixture = fixture()
    files = fixture.manifest["files"]

    for altered <-
          [
            [],
            [nil],
            files ++ [hd(files)],
            [Map.put(hd(files), "path", "../escape") | tl(files)],
            [Map.put(hd(files), "blob", "bad") | tl(files)],
            [Map.put(hd(files), "role", "unknown") | tl(files)],
            [%{"path" => "x"}],
            [Map.put(hd(files), "path", @path) | tl(files)]
          ] ++
            Enum.map(["asset", "preview", "review_page"], fn role -> Enum.reject(files, &(&1["role"] == role)) end) do
      assert {:error, _} = verify(fixture_bytes(Jason.encode!(%{fixture.manifest | "files" => altered})))
    end

    for mode <- ["120000", "160000"] do
      changed = update_in(fixture, [:tree, "tree"], fn [first | rest] -> [%{first | "mode" => mode} | rest] end)
      assert {:error, _} = verify(changed)
    end

    tree = update_in(fixture.tree, ["tree"], &(&1 ++ [%{"path" => "assets/hit.wav.import", "type" => "blob", "mode" => "100644", "sha" => @blob}]))
    assert {:error, :github_asset_manifest_mismatch} = verify(%{fixture | tree: tree})
    manifest = Map.update!(fixture.manifest, "files", &(&1 ++ [%{"path" => "assets/hit.wav.import", "blob" => @blob, "role" => "import"}]))
    assert :ok = verify(fixture_bytes(Jason.encode!(manifest)))
  end

  defp criterion do
    %{
      "id" => "A1",
      "description" => "Impact fits the scene",
      "covers" => ["R1"],
      "validation" => %{"kind" => "human_asset", "manifest" => @path, "reviewers" => ["human"], "instructions" => "Audition in the gameplay mix"}
    }
  end

  defp evidence(sha),
    do: %{
      "validation" => %{"sha" => sha, "command" => "audio tests", "result" => "passed"},
      "acceptance" => [%{"id" => "A1", "sha" => sha, "result" => "passed", "details" => "Listened in context", "approval_comment_id" => 7}]
    }

  defp issue,
    do: %Issue{
      id: "2",
      description: Acceptance.render([criterion()]),
      labels: ["type:task"],
      native_ref: %{"repo" => "owner/repo", "parent" => %{"repo" => "owner/repo", "number" => 1, "in_project" => true, "labels" => ["type:feature"]}}
    }

  defp fixture do
    files =
      Enum.map(
        [{"assets/hit.wav", "asset"}, {"reviews/impact/v1/media/0.wav", "preview"}, {"reviews/impact/v1/index.html", "review_page"}],
        fn {path, role} -> %{"path" => path, "blob" => @blob, "role" => role} end
      )

    fixture_bytes(Jason.encode!(%{"version" => 1, "asset_id" => "impact", "files" => files}))
  end

  defp fixture_bytes(bytes) do
    hash = :crypto.hash(:sha, "blob #{byte_size(bytes)}\0" <> bytes) |> Base.encode16(case: :lower)

    manifest =
      case Jason.decode(bytes) do
        {:ok, %{} = m} -> m
        _ -> %{}
      end

    files = Enum.filter(manifest["files"] || [], &(is_map(&1) and is_binary(&1["path"])))
    tree = Enum.map(files, &%{"path" => &1["path"], "sha" => &1["blob"], "mode" => "100644", "type" => "blob"})
    approval = %{"version" => 1, "decision" => "approved", "criterion" => criterion(), "manifest" => @path, "manifest_blob" => hash}

    %{
      manifest: manifest,
      approval: approval,
      comment: comment(approval),
      tree: %{"tree" => tree ++ [%{"path" => @path, "sha" => hash, "mode" => "100644", "type" => "blob"}], "truncated" => false},
      content: %{"encoding" => "base64", "content" => Base.encode64(bytes)}
    }
  end

  defp comment(approval),
    do: %{
      "user" => %{"type" => "User", "login" => "human"},
      "issue_url" => "https://api.github.com/repos/owner/repo/issues/2",
      "body" => "## Asset Approval\n```symphony-asset-approval\n" <> Jason.encode!(approval) <> "\n```"
    }

  defp getter(fixture) do
    fn
      "/issues/comments/7" -> {:ok, fixture.comment}
      "/git/trees/" <> _ -> {:ok, fixture.tree}
      "/git/blobs/" <> _ -> {:ok, fixture.content}
      "/git/ref/heads/task/GH-2" -> {:ok, %{"object" => %{"type" => "commit", "sha" => @source}}}
      "/git/ref/heads/feature/GH-1" -> {:ok, %{"object" => %{"type" => "commit", "sha" => @target}}}
      "/compare/" <> _ -> {:ok, %{"merge_base_commit" => %{"sha" => @source}}}
    end
  end

  defp verify(fixture), do: Acceptance.verify([criterion()], evidence(@source), @source, getter(fixture), issue_id: "2")
end
