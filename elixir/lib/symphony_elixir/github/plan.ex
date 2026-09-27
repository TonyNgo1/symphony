defmodule SymphonyElixir.GitHub.Plan do
  @moduledoc "Offline validator and issue-body compiler for an approved task graph. No GitHub writes."
  alias SymphonyElixir.GitHub.Acceptance

  @spec compile(term()) :: {:ok, map()} | {:error, term()}
  def compile(plan) do
    with :ok <- shape(plan),
         :ok <- relationships(plan["issues"]),
         :ok <- coverage(plan),
         :ok <- acyclic(plan["issues"]) do
      {:ok, %{"version" => 1, "repository" => plan["repository"], "project_number" => plan["project_number"], "issues" => Enum.map(plan["issues"], &render/1)}}
    end
  end

  defp shape(%{"version" => 1, "repository" => repo, "project_number" => project, "requirements" => requirements, "issues" => issues} = plan) do
    valid =
      keys?(plan, ["version", "repository", "project_number", "requirements", "issues"]) and
        repository?(repo) and is_integer(project) and project > 0 and
        collection?(requirements, "id", &requirement?/1) and collection?(issues, "key", &issue?/1)

    if valid, do: :ok, else: {:error, :invalid_plan_schema}
  end

  defp shape(_), do: {:error, :invalid_plan_schema}

  defp requirement?(%{"id" => id, "description" => description} = value),
    do: keys?(value, ["id", "description"]) and key?(id) and text?(description)

  defp requirement?(_), do: false

  defp issue?(%{"key" => key, "kind" => kind, "title" => title, "objective" => objective, "blocked_by" => blockers, "acceptance" => criteria} = issue) do
    keys?(issue, ["key", "kind", "title", "objective", "blocked_by", "acceptance", "parent", "bug", "asset_generation"]) and
      key?(key) and kind in ["feature", "task"] and text?(title) and objective?(objective) and blockers?(blockers) and
      is_boolean(Map.get(issue, "bug", false)) and Acceptance.validate(criteria) == :ok and asset_generation?(issue)
  end

  defp issue?(_), do: false

  defp asset_generation?(issue) do
    case Map.get(issue, "asset_generation", false) do
      false -> true
      true -> Enum.any?(issue["acceptance"], &(&1["validation"]["kind"] == "human_asset"))
      _ -> false
    end
  end

  defp collection?(values, key, validator), do: is_list(values) and values != [] and Enum.all?(values, validator) and unique?(values, key)
  defp repository?(repo), do: is_binary(repo) and Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, repo)
  defp objective?(value), do: text?(value) and not String.contains?(value, "```symphony-acceptance")
  defp blockers?(values), do: is_list(values) and Enum.all?(values, &key?/1) and length(values) == length(Enum.uniq(values))

  defp relationships(issues) do
    by_key = Map.new(issues, &{&1["key"], &1})

    Enum.reduce_while(issues, :ok, fn issue, :ok ->
      if valid_relationships?(issue, by_key),
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_plan_relationships, issue["key"]}}}
    end)
  end

  defp valid_relationships?(issue, by_key) do
    blockers = issue["blocked_by"]
    valid_blockers = Enum.all?(blockers, &(Map.has_key?(by_key, &1) and &1 != issue["key"]))
    parent = by_key[issue["parent"]]

    case issue["kind"] do
      "feature" -> valid_blockers and is_nil(issue["parent"]) and Enum.any?(by_key, fn {_, child} -> child["parent"] == issue["key"] end)
      "task" -> valid_blockers and is_map(parent) and parent["kind"] == "feature"
    end
  end

  defp coverage(plan) do
    required = MapSet.new(plan["requirements"], & &1["id"])
    criteria = Enum.flat_map(plan["issues"], & &1["acceptance"])
    covered = MapSet.new(Enum.flat_map(criteria, &(&1["covers"] || [])))

    if Enum.all?(criteria, &is_list(&1["covers"])) and MapSet.equal?(required, covered),
      do: :ok,
      else: {:error, {:invalid_plan_coverage, %{missing: MapSet.difference(required, covered) |> Enum.sort(), unknown: MapSet.difference(covered, required) |> Enum.sort()}}}
  end

  defp acyclic(issues) do
    # Model bootstrap separately from completion. A child's need for its parent's
    # bootstrap is NOT a blocked-by edge on the parent's completion.
    graph =
      Enum.reduce(issues, %{}, fn issue, graph ->
        key = issue["key"]
        blockers = Enum.map(issue["blocked_by"], &{&1, :done})

        if issue["kind"] == "feature" do
          children = issues |> Enum.filter(&(&1["parent"] == key)) |> Enum.map(&{&1["key"], :done})
          graph |> Map.put({key, :start}, blockers) |> Map.put({key, :done}, [{key, :start} | children])
        else
          Map.put(graph, {key, :done}, [{issue["parent"], :start} | blockers])
        end
      end)

    drain(graph)
  end

  defp drain(graph) when map_size(graph) == 0, do: :ok

  defp drain(graph) do
    ready = for {key, []} <- graph, do: key

    if ready == [] do
      {:error, {:plan_dependency_deadlock, graph |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()}}
    else
      graph |> Map.drop(ready) |> Map.new(fn {key, deps} -> {key, deps -- ready} end) |> drain()
    end
  end

  defp render(issue) do
    labels = ["symphony", "type:" <> issue["kind"]] ++ if(issue["bug"] == true, do: ["bug"], else: [])
    labels = labels ++ if(issue["asset_generation"] == true, do: ["asset-generation"], else: [])
    body = "## Objective\n#{issue["objective"]}\n\n## Acceptance\n" <> Acceptance.render(issue["acceptance"])
    %{"key" => issue["key"], "title" => issue["title"], "body" => body, "labels" => labels, "status" => "Backlog", "parent" => issue["parent"], "blocked_by" => issue["blocked_by"]}
  end

  defp keys?(value, allowed), do: Map.keys(value) -- allowed == []
  defp unique?(values, key), do: length(values) == length(Enum.uniq_by(values, & &1[key]))
  defp key?(value), do: is_binary(value) and Regex.match?(~r/^[A-Za-z][A-Za-z0-9_-]*$/, value)
  defp text?(value), do: is_binary(value) and String.trim(value) != ""
end
