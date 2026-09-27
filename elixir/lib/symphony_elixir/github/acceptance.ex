defmodule SymphonyElixir.GitHub.Acceptance do
  @moduledoc "Shared, versioned acceptance contract for planning and completion."

  alias SymphonyElixir.GitHub.AssetReview
  @block ~r/^```symphony-acceptance\r?\n(.*?)^```\s*$/ms

  @spec parse(term()) :: {:ok, [map()]} | {:error, term()}
  def parse(body) when is_binary(body) do
    with [[_, json]] <- Regex.scan(@block, body),
         {:ok, %{"version" => 1, "criteria" => criteria} = contract} <- Jason.decode(json),
         true <- map_size(contract) == 2,
         :ok <- validate(criteria) do
      {:ok, criteria}
    else
      _ -> {:error, :github_invalid_acceptance_contract}
    end
  end

  def parse(_), do: {:error, :github_invalid_acceptance_contract}

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(criteria) when is_list(criteria) and criteria != [] do
    if Enum.all?(criteria, &criterion?/1) and unique?(Enum.map(criteria, & &1["id"])),
      do: :ok,
      else: {:error, :github_invalid_acceptance_contract}
  end

  def validate(_), do: {:error, :github_invalid_acceptance_contract}

  @spec render([map()]) :: String.t()
  def render(criteria), do: "```symphony-acceptance\n" <> Jason.encode!(%{"version" => 1, "criteria" => criteria}, pretty: true) <> "\n```"

  @spec fingerprint([map()]) :: String.t()
  def fingerprint(criteria) do
    # Canonical field order, independent of JSON object key and criterion order.
    canonical = criteria |> Enum.sort_by(& &1["id"]) |> Enum.map(&canonical/1)
    :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
  end

  @spec verify([map()], term(), String.t(), function()) :: :ok | {:error, term()}
  def verify(criteria, evidence, sha, get), do: verify(criteria, evidence, sha, get, [])

  @spec verify([map()], term(), String.t(), function(), keyword()) :: :ok | {:error, term()}
  def verify(criteria, %{"acceptance" => entries}, sha, get, opts) when is_list(entries) do
    expected = Enum.map(criteria, & &1["id"]) |> Enum.sort()
    actual = Enum.map(entries, fn entry -> if is_map(entry), do: entry["id"] end)

    if Enum.all?(actual, &is_binary/1) and Enum.sort(actual) == expected do
      verify_entries(criteria, Map.new(entries, &{&1["id"], &1}), sha, get, opts)
    else
      {:error, {:github_acceptance_coverage_mismatch, expected}}
    end
  end

  def verify(_criteria, _evidence, _sha, _get, _opts), do: {:error, :github_acceptance_evidence_required}

  defp verify_entries(criteria, by_id, sha, get, opts) do
    Enum.reduce_while(criteria, :ok, fn criterion, :ok ->
      case verify_entry(criterion, by_id[criterion["id"]], sha, get, opts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp verify_entry(criterion, %{"sha" => sha, "result" => "passed", "details" => details} = entry, sha, get, opts) do
    if text?(details),
      do: verify_policy(criterion, entry, sha, get, opts),
      else: {:error, {:github_invalid_acceptance_evidence, criterion["id"]}}
  end

  defp verify_entry(criterion, _entry, _sha, _get, _opts), do: {:error, {:github_invalid_acceptance_evidence, criterion["id"]}}

  defp verify_policy(%{"validation" => %{"kind" => "human_asset"} = policy} = criterion, entry, sha, get, opts),
    do: AssetReview.verify(policy, entry, sha, get, Keyword.put(opts, :criterion, criterion))

  defp verify_policy(criterion, entry, sha, get, _opts), do: verify_check(criterion["validation"], entry, sha, get)

  defp verify_check(%{"kind" => "review"}, _entry, _sha, _get), do: :ok

  defp verify_check(%{"kind" => "github_check", "name" => name, "app_id" => app_id}, %{"check_run_id" => id}, sha, get)
       when is_integer(id) and id > 0 do
    case get.("/check-runs/#{id}") do
      {:ok, %{"name" => ^name, "head_sha" => ^sha, "status" => "completed", "conclusion" => "success", "app" => %{"id" => ^app_id}}} -> :ok
      {:error, _} = error -> error
      _ -> {:error, :github_acceptance_check_not_successful}
    end
  end

  defp verify_check(_validation, _entry, _sha, _get), do: {:error, :github_acceptance_check_required}

  defp criterion?(%{"id" => id, "description" => description, "validation" => validation} = criterion) do
    Map.keys(criterion) -- ["id", "description", "validation", "covers"] == [] and
      is_binary(id) and Regex.match?(~r/^A[1-9][0-9]*$/, id) and text?(description) and validation?(validation) and covers?(criterion["covers"])
  end

  defp criterion?(_), do: false
  defp validation?(%{"kind" => "review", "instructions" => instructions} = value), do: map_size(value) == 2 and text?(instructions)

  defp validation?(%{"kind" => "github_check", "name" => name, "app_id" => app_id} = value),
    do: map_size(value) == 3 and text?(name) and is_integer(app_id) and app_id > 0

  defp validation?(value), do: AssetReview.policy?(value)
  defp covers?(nil), do: true
  defp covers?(ids) when is_list(ids), do: ids != [] and Enum.all?(ids, &text?/1) and unique?(ids)
  defp covers?(_), do: false
  defp unique?(values), do: length(values) == length(Enum.uniq(values))
  defp text?(value), do: is_binary(value) and String.trim(value) != ""

  defp canonical(criterion) do
    validation = criterion["validation"]
    base = [criterion["id"], criterion["description"], validation["kind"], validation["instructions"], validation["name"], validation["app_id"], Enum.sort(criterion["covers"] || [])]
    if validation["kind"] == "human_asset", do: base ++ [validation["manifest"], Enum.sort(validation["reviewers"])], else: base
  end
end
