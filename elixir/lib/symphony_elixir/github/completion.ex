defmodule SymphonyElixir.GitHub.Completion do
  @moduledoc "Commit-bound review and integration evidence for GitHub status transitions."
  alias SymphonyElixir.GitHub.Acceptance

  @spec review(map(), term(), function()) :: {:ok, map()} | {:error, term()}
  def review(issue, evidence, get) do
    with {:ok, sha} <- head(source_branch(issue), get),
         :ok <- validation(evidence, sha),
         :ok <- regression(issue, evidence),
         {:ok, criteria} <- Acceptance.parse(issue.description),
         :ok <- Acceptance.verify(criteria, evidence, sha, get, issue_id: issue.id) do
      {:ok,
       %{"sha" => sha, "validation" => evidence["validation"], "regression" => evidence["regression"], "acceptance" => evidence["acceptance"], "acceptance_hash" => Acceptance.fingerprint(criteria)}}
    end
  end

  @spec finish(map(), term(), term(), function()) :: :ok | {:error, term()}
  def finish(issue, evidence, record, get) do
    with %{"sha" => reviewed} <- record,
         true <- sha?(reviewed),
         :ok <- validation(record, reviewed),
         :ok <- regression(issue, record),
         {:ok, criteria} <- Acceptance.parse(issue.description),
         true <- record["acceptance_hash"] == Acceptance.fingerprint(criteria),
         :ok <- Acceptance.verify(criteria, record, reviewed, get, issue_id: issue.id),
         {:ok, ^reviewed} <- head(source_branch(issue), get),
         {:ok, target} <- target_branch(issue),
         {:ok, integrated} <- head(target, get),
         :ok <- validation(evidence, integrated),
         :ok <- Acceptance.verify(criteria, evidence, integrated, get, issue_id: issue.id),
         {:ok, %{"merge_base_commit" => %{"sha" => ^reviewed}}} <- get.("/compare/#{reviewed}...#{integrated}") do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :github_review_or_ancestry_mismatch}
    end
  end

  @spec read_record(String.t() | nil) :: map() | nil
  def read_record(body) do
    case record_lines(body) do
      ["Review: " <> json] ->
        case Jason.decode(json) do
          {:ok, record} when is_map(record) -> record
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @spec preserve_record(String.t(), String.t() | nil, keyword()) :: String.t()
  def preserve_record(body, previous, opts) do
    record = Keyword.get_lazy(opts, :review_record, fn -> read_record(previous) end)
    lines = body |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "Review: "))
    lines = if is_map(record), do: lines ++ ["Review: " <> Jason.encode!(record)], else: lines
    Enum.join(lines, "\n")
  end

  defp record_lines(body), do: (body || "") |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "Review: "))

  defp source_branch(issue) do
    prefix = if "type:feature" in issue.labels, do: "feature", else: "task"
    "#{prefix}/GH-#{issue.id}"
  end

  defp target_branch(%{labels: labels, native_ref: native}) do
    if "type:feature" in labels do
      {:ok, "main"}
    else
      parent_target(native["parent"], native["repo"])
    end
  end

  defp parent_target(%{"in_project" => true, "number" => number, "repo" => repo, "labels" => labels}, repo)
       when is_integer(number) and number > 0 do
    if "type:feature" in labels, do: {:ok, "feature/GH-#{number}"}, else: {:error, :github_invalid_integration_target}
  end

  defp parent_target(_, _), do: {:error, :github_invalid_integration_target}

  defp head(branch, get) do
    with {:ok, %{"object" => %{"type" => "commit", "sha" => sha}}} <- get.("/git/ref/heads/#{branch}"),
         true <- sha?(sha) do
      {:ok, sha}
    else
      {:error, _} = error -> error
      _ -> {:error, :github_invalid_branch_head}
    end
  end

  defp validation(%{"validation" => %{"sha" => sha, "command" => command, "result" => "passed"}}, expected) do
    if sha == expected and text?(command), do: :ok, else: {:error, :github_invalid_validation_evidence}
  end

  defp validation(_, _), do: {:error, :github_invalid_validation_evidence}

  defp regression(%{labels: labels}, evidence) do
    if "bug" in labels, do: regression_evidence(evidence), else: :ok
  end

  defp regression_evidence(%{
         "regression" => %{"test" => test, "command" => command, "before_sha" => before_sha, "before" => "failed", "after" => "passed"},
         "validation" => %{"sha" => after_sha}
       }) do
    if text?(test) and text?(command) and sha?(before_sha) and before_sha != after_sha,
      do: :ok,
      else: {:error, :github_regression_evidence_required}
  end

  defp regression_evidence(_), do: {:error, :github_regression_evidence_required}
  defp sha?(sha), do: is_binary(sha) and Regex.match?(~r/^[0-9a-f]{40}$/, sha)
  defp text?(text), do: is_binary(text) and String.trim(text) != ""
end
