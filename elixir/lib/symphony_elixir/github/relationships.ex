defmodule SymphonyElixir.GitHub.Relationships do
  @moduledoc "Fresh, bounded GraphQL batches of native issue relationships."

  @query """
  query SymphonyRelationships($ids: [ID!]!) {
    nodes(ids: $ids) {
      ... on Issue {
        id number
        blockedBy(first: 20) { nodes { ...RelatedIssue } pageInfo { hasNextPage } }
        subIssues(first: 20) { nodes { ...RelatedIssue } pageInfo { hasNextPage } }
        parent { ...RelatedIssue }
      }
    }
    rateLimit { cost remaining resetAt }
  }
  fragment RelatedIssue on Issue {
    number state url repository { nameWithOwner }
    labels(first: 20) { nodes { name } pageInfo { hasNextPage } }
  }
  """

  @spec fetch([map()], map(), function()) :: {:ok, map()} | {:error, term()}
  def fetch(items, config, request) do
    items
    |> Enum.chunk_every(10)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, acc} ->
      case fetch_batch(batch, config, request) do
        {:ok, relationships} -> {:cont, {:ok, Map.merge(acc, relationships)}}
        error -> {:halt, error}
      end
    end)
  end

  defp fetch_batch(items, config, request) do
    ids = Enum.map(items, & &1.raw["node_id"])

    if Enum.all?(ids, &(is_binary(&1) and &1 != "")) do
      body = %{"query" => @query, "variables" => %{"ids" => ids}}

      case request.("POST", "/graphql", %{}, body, config) do
        {:ok, %{status: 200, body: %{"errors" => errors}}} when errors != [] ->
          {:error, :github_graphql_errors}

        {:ok, %{status: 200, body: %{"data" => %{"nodes" => nodes}}}} when is_list(nodes) ->
          decode_batch(items, nodes)

        {:ok, %{status: status}} when status != 200 ->
          {:error, {:github_api_status, status}}

        {:error, _} = error ->
          error

        _ ->
          {:error, :github_invalid_relationship_payload}
      end
    else
      {:error, :github_missing_issue_node_id}
    end
  end

  defp decode_batch(items, nodes) when length(items) == length(nodes) do
    Enum.zip(items, nodes)
    |> Enum.reduce_while({:ok, %{}}, fn {item, node}, {:ok, acc} ->
      case decode_item(item, node) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, item.raw["number"], value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_batch(_, _), do: {:error, :github_invalid_relationship_payload}

  defp decode_item(item, node) do
    if is_map(node) and node["id"] == item.raw["node_id"] and node["number"] == item.raw["number"] do
      decode(node)
    else
      {:error, :github_invalid_relationship_payload}
    end
  end

  defp decode(node) do
    with {:ok, blockers} <- connection(node["blockedBy"], &related/1),
         {:ok, children} <- connection(node["subIssues"], &related/1),
         {:ok, parent} <- parent(node) do
      {:ok, %{blockers: blockers, children: children, parent: parent}}
    else
      # Only explicitly truncated connections fall back to fully paginated REST.
      :overflow -> {:ok, :rest}
      error -> error
    end
  end

  defp parent(%{"parent" => nil}), do: {:ok, nil}
  defp parent(%{"parent" => value}), do: related(value)
  defp parent(_), do: {:error, :github_invalid_relationship_payload}

  defp connection(%{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}, decode) when is_list(nodes) do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case decode.(node) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp connection(%{"pageInfo" => %{"hasNextPage" => true}}, _), do: :overflow
  defp connection(_, _), do: {:error, :github_invalid_relationship_payload}

  defp related(%{"number" => number, "state" => state, "url" => url, "repository" => %{"nameWithOwner" => repo}, "labels" => labels})
       when is_integer(number) and number > 0 and state in ["OPEN", "CLOSED"] and is_binary(url) and is_binary(repo) do
    with {:ok, labels} <- connection(labels, &label/1) do
      {:ok, %{"number" => number, "state" => String.downcase(state), "html_url" => url, "repository_url" => "/repos/" <> repo, "labels" => labels}}
    end
  end

  defp related(_), do: {:error, :github_invalid_relationship_payload}
  defp label(%{"name" => name}) when is_binary(name), do: {:ok, %{"name" => name}}
  defp label(_), do: {:error, :github_invalid_relationship_payload}
end
