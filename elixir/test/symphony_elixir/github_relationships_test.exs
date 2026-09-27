defmodule SymphonyElixir.GitHub.RelationshipsTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GitHub.Relationships

  test "transport and API failures never become an empty dependency list" do
    for result <- [{:error, :timeout}, {:ok, %{status: 403}}, {:ok, %{status: 200, body: %{}}}] do
      assert {:error, _} = fetch(result)
    end
  end

  test "missing parent metadata and malformed related issues or labels fail closed" do
    empty = connection([])
    node = %{"id" => "I_1", "number" => 1, "blockedBy" => empty, "subIssues" => empty, "parent" => nil}
    related = %{"number" => 2, "state" => "OPEN", "url" => "https://github.test/o/r/issues/2", "repository" => %{"nameWithOwner" => "o/r"}, "labels" => connection([%{"name" => 123}])}

    broken_nodes = [Map.delete(node, "parent"), Map.put(node, "blockedBy", connection([nil])), Map.put(node, "parent", related)]

    for broken <- broken_nodes do
      result = fetch({:ok, %{status: 200, body: %{"data" => %{"nodes" => [broken]}}}})
      assert {:error, :github_invalid_relationship_payload} = result
    end
  end

  defp connection(nodes), do: %{"nodes" => nodes, "pageInfo" => %{"hasNextPage" => false}}
  defp fetch(result), do: Relationships.fetch([%{raw: %{"node_id" => "I_1", "number" => 1}}], %{}, fn _, _, _, _, _ -> result end)
end
