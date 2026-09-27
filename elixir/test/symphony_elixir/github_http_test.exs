defmodule SymphonyElixir.GitHub.HttpTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.GitHub.Http

  setup do
    server = start_supervised!({Http, name: nil})
    %{server: server}
  end

  test "conditional reads retain pagination and revalidate rather than return a stale snapshot", %{server: server} do
    first = %{status: 200, body: [%{"state" => "Ready"}], headers: %{"etag" => ["v1"], "link" => ["next-page"]}}
    assert {:ok, ^first} = Http.request(opts(), server: server, sender: fn _ -> {:ok, first} end)

    unchanged = fn request ->
      assert List.keyfind(request[:headers], "if-none-match", 0) == {"if-none-match", "v1"}
      assert request[:retry] == false
      {:ok, %{status: 304, body: nil, headers: %{}}}
    end

    assert {:ok, ^first} = Http.request(opts(), server: server, sender: unchanged)
    changed = %{first | body: [%{"state" => "Human Review"}], headers: %{"etag" => ["v2"]}}
    assert {:ok, ^changed} = Http.request(opts(), server: server, sender: fn _ -> {:ok, changed} end)
    assert Http.stats(server).not_modified == 1
    assert Http.stats(server).rest == 3
    assert {:error, :offline} = Http.request(opts(), server: server, sender: fn _ -> {:error, :offline} end)
  end

  test "cached representations are isolated by credentials, query and server restart", %{server: server} do
    Http.request(opts(), server: server, sender: fn _ -> ok(%{"etag" => ["private"]}) end)

    for changed <- [Keyword.put(opts(), :headers, [{"authorization", "other"}]), Keyword.put(opts(), :params, %{"fields" => "model"})] do
      Http.request(changed,
        server: server,
        sender: fn request ->
          refute List.keymember?(request[:headers], "if-none-match", 0)
          ok()
        end
      )
    end

    stop_supervised!(Http)
    restarted = start_supervised!({Http, name: nil})

    Http.request(opts(),
      server: restarted,
      sender: fn request ->
        refute List.keymember?(request[:headers], "if-none-match", 0)
        ok()
      end
    )
  end

  test "mutation attempts clear representations but GraphQL reads preserve them", %{server: server} do
    Http.request(opts(), server: server, sender: fn _ -> ok(%{"etag" => ["v1"]}) end)

    graph =
      opts()
      |> Keyword.put(:method, :post)
      |> Keyword.put(:url, "https://api.github.test/graphql")
      |> Keyword.put(:json, %{"query" => "query Batch { nodes { id } }"})

    cost = %{status: 200, body: %{"data" => %{"rateLimit" => %{"cost" => 2}}}, headers: %{}}
    Http.request(graph, server: server, sender: fn _ -> {:ok, cost} end)

    Http.request(opts(),
      server: server,
      sender: fn request ->
        assert List.keyfind(request[:headers], "if-none-match", 0) == {"if-none-match", "v1"}
        ok(%{"etag" => ["v1"]})
      end
    )

    Http.request(Keyword.put(opts(), :method, :patch), server: server, sender: fn _ -> {:error, :timeout} end)

    Http.request(opts(),
      server: server,
      sender: fn request ->
        refute List.keymember?(request[:headers], "if-none-match", 0)
        ok()
      end
    )

    assert Http.stats(server).graphql_cost == 2
  end

  test "REST exhaustion pauses all workers sharing the token until reset, with separate GraphQL accounting", %{server: server} do
    reset = System.system_time(:second) + 600
    headers = %{"x-ratelimit-remaining" => ["0"], "x-ratelimit-reset" => [to_string(reset)]}
    exhausted = %{status: 403, body: %{}, headers: headers}
    assert {:ok, _} = Http.request(opts(), server: server, sender: fn _ -> {:ok, exhausted} end)

    for _ <- 1..8 do
      result = Http.request(opts(), server: server, sender: fn _ -> flunk("request sent during quota pause") end)
      assert {:error, {:github_rate_limited, ^reset}} = result
    end

    assert Http.stats(server).suppressed == 8
    graph = opts() |> Keyword.put(:method, :post) |> Keyword.put(:url, "https://api.github.test/graphql")
    assert {:ok, _} = Http.request(graph, server: server, sender: fn _ -> ok() end)

    :sys.replace_state(server, fn state ->
      limits = Map.new(state.limits, fn {key, limit} -> {key, %{limit | blocked_until: System.system_time(:second) - 1}} end)
      %{state | limits: limits}
    end)

    assert {:ok, _} = Http.request(opts(), server: server, sender: fn _ -> ok() end)
  end

  test "secondary Retry-After pauses reads and writes; errors without cache never become success", %{server: server} do
    before = System.system_time(:second)
    response = %{status: 429, body: %{}, headers: %{"retry-after" => ["120"]}}
    assert {:ok, _} = Http.request(opts(), server: server, sender: fn _ -> {:ok, response} end)
    result = Http.request(Keyword.put(opts(), :method, :patch), server: server, sender: fn _ -> flunk("mutation replayed") end)
    assert {:error, {:github_rate_limited, until}} = result
    assert until >= before + 120
  end

  test "late concurrent responses cannot shorten a secondary quota pause", %{server: server} do
    owner = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Http.request(opts(),
            server: server,
            sender: fn _ ->
              send(owner, {:waiting, self()})

              receive do
                {:response, response} -> {:ok, response}
              end
            end
          )
        end)
      end

    assert_receive {:waiting, first}
    assert_receive {:waiting, second}
    send(first, {:response, %{status: 429, headers: %{"retry-after" => ["600"]}}})
    Task.await(Enum.find(tasks, &(&1.pid == first)))
    [limit] = Enum.filter(Http.stats(server).limits, &(&1.resource == :all))
    send(second, {:response, %{status: 429, headers: %{"retry-after" => ["1"]}}})
    Task.await(Enum.find(tasks, &(&1.pid == second)))
    assert {:error, {:github_rate_limited, until}} = Http.request(opts(), server: server)
    assert until == limit.blocked_until
  end

  test "a permissions error does not globally pause unrelated API requests", %{server: server} do
    forbidden = %{status: 403, body: %{"message" => "Resource not accessible by personal access token"}, headers: %{}}
    assert {:ok, ^forbidden} = Http.request(opts(), server: server, sender: fn _ -> {:ok, forbidden} end)
    assert {:ok, _} = Http.request(opts(), server: server, sender: fn _ -> ok() end)
    assert Http.stats(server).suppressed == 0
  end

  test "secondary 403 backoff survives malformed quota headers", %{server: server} do
    response = %{status: 403, headers: %{"retry-after" => ["60"], "x-ratelimit-remaining" => ["invalid"]}}
    assert {:ok, ^response} = Http.request(opts(), server: server, sender: fn _ -> {:ok, response} end)
    assert {:error, {:github_rate_limited, _}} = Http.request(opts(), server: server)
    assert Http.stats(server).suppressed == 1
  end

  test "the default request entry point respects the supervised quota gate" do
    # Use an isolated scope; the blocked request must never reach the network.
    request = Keyword.put(opts(), :headers, [{"authorization", "isolated-#{System.unique_integer()}"}])
    response = %{status: 429, headers: %{"retry-after" => ["60"]}}
    Http.request(request, sender: fn _ -> {:ok, response} end)
    assert {:error, {:github_rate_limited, _}} = Http.request(request)
  end

  defp opts, do: [method: :get, url: "https://api.github.test/items", params: %{}, headers: [{"authorization", "secret"}]]
  defp ok(headers \\ %{}), do: {:ok, %{status: 200, body: [], headers: headers}}
end
