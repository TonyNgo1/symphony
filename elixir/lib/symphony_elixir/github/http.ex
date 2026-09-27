defmodule SymphonyElixir.GitHub.Http do
  @moduledoc "Conditional REST reads, shared quota backoff and request accounting. Never serves stale data on errors."
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, [], name: Keyword.get(opts, :name, __MODULE__))

  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @spec request(keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(opts, runtime \\ []) do
    server = Keyword.get(runtime, :server, __MODULE__)
    sender = Keyword.get(runtime, :sender, &Req.request/1)
    scope = :crypto.hash(:sha256, :erlang.term_to_binary(opts[:headers]))
    resource = if String.ends_with?(opts[:url], "/graphql"), do: :graphql, else: :rest
    scope = {URI.parse(opts[:url]).host, scope}
    key = {scope, opts[:url], opts[:params]}
    method = request_kind(opts, resource)

    with {:ok, cached} <- GenServer.call(server, {:prepare, scope, resource, key, opts[:method]}) do
      headers = if cached, do: [{"if-none-match", cached.etag} | opts[:headers]], else: opts[:headers]
      result = sender.(Keyword.put(opts, :headers, headers) |> Keyword.put(:retry, false))
      GenServer.call(server, {:complete, scope, resource, key, method, cached, result})
    end
  end

  defp request_kind(opts, :graphql) do
    if is_map(opts[:json]) and String.starts_with?(opts[:json]["query"] || "", "query "),
      do: :query,
      else: opts[:method]
  end

  defp request_kind(opts, _), do: opts[:method]

  @impl true
  def init(_), do: {:ok, %{cache: %{}, limits: %{}, counts: %{rest: 0, graphql: 0, not_modified: 0, suppressed: 0, graphql_cost: 0}}}

  @impl true
  def handle_call(:stats, _from, state) do
    limits = Enum.map(state.limits, fn {{_scope, resource}, value} -> Map.put(value, :resource, resource) end)
    {:reply, Map.put(state.counts, :limits, limits), state}
  end

  def handle_call({:prepare, scope, resource, key, method}, _from, state) do
    until = Enum.max([blocked_until(state, {scope, resource}), blocked_until(state, {scope, :all})])

    if until > System.system_time(:second) do
      {:reply, {:error, {:github_rate_limited, until}}, update_in(state.counts.suppressed, &(&1 + 1))}
    else
      cached = if method == :get, do: state.cache[key]
      cached = if cached && cached.expires > System.monotonic_time(:second), do: cached
      {:reply, {:ok, cached}, update_in(state.counts[resource], &(&1 + 1))}
    end
  end

  def handle_call({:complete, scope, resource, key, method, cached, result}, _from, state) do
    state = remember_limits(state, scope, resource, result)
    {reply, state} = response(state, key, scope, method, cached, result)
    {:reply, reply, state}
  end

  defp response(state, _key, _scope, :get, cached, {:ok, %{status: 304} = response}) when not is_nil(cached) do
    # Retain pagination headers from the validated representation if absent on 304.
    headers = Map.merge(cached.response.headers, Map.get(response, :headers, %{}))
    response = %{cached.response | headers: headers}
    {{:ok, response}, update_in(state.counts.not_modified, &(&1 + 1))}
  end

  defp response(state, key, _scope, :get, _cached, {:ok, %{status: 200} = response} = result) do
    case header(response, "etag") do
      etag when is_binary(etag) ->
        entry = %{
          etag: etag,
          response: Map.put_new(response, :headers, %{}),
          expires: System.monotonic_time(:second) + 300
        }

        cache = if map_size(state.cache) >= 512, do: %{}, else: state.cache
        {result, %{state | cache: Map.put(cache, key, entry)}}

      _ ->
        {result, %{state | cache: Map.delete(state.cache, key)}}
    end
  end

  defp response(state, key, scope, method, _cached, result) do
    cache =
      case method do
        :get ->
          Map.delete(state.cache, key)

        :query ->
          state.cache

        _ ->
          # Clear on attempted mutation, including ambiguous transport failures.
          Map.reject(state.cache, fn {{entry_scope, _, _}, _} -> entry_scope == scope end)
      end

    {result, %{state | cache: cache}}
  end

  defp remember_limits(state, scope, resource, {:ok, response}) do
    remaining = integer(header(response, "x-ratelimit-remaining"))
    reset = integer(header(response, "x-ratelimit-reset"))
    now = System.system_time(:second)
    previous = Map.get(state.limits, {scope, resource}, %{})
    until = if remaining == 0, do: max(reset || now + 60, now + 1), else: 0
    limit = Map.merge(previous, %{remaining: remaining, reset: reset, blocked_until: max(until, Map.get(previous, :blocked_until, 0))})
    state = put_in(state.limits[{scope, resource}], limit)

    state = remember_secondary_limit(state, scope, response, now)
    remember_cost(state, resource, response)
  end

  defp remember_limits(state, _scope, _resource, _), do: state

  defp remember_secondary_limit(state, scope, response, now) do
    retry = integer(header(response, "retry-after"))

    if secondary_limit?(response, retry) do
      until = max(now + max(retry || 60, 1), blocked_until(state, {scope, :all}))
      put_in(state.limits[{scope, :all}], %{blocked_until: until})
    else
      state
    end
  end

  defp secondary_limit?(%{status: 429}, _retry), do: true
  defp secondary_limit?(%{status: 403}, retry) when is_integer(retry), do: true

  defp secondary_limit?(%{status: 403, body: %{"message" => message}}, _) when is_binary(message),
    do: String.contains?(String.downcase(message), "secondary rate limit")

  defp secondary_limit?(_, _), do: false

  defp remember_cost(state, resource, response) do
    case response do
      %{body: %{"data" => %{"rateLimit" => %{"cost" => cost}}}} when resource == :graphql and is_integer(cost) ->
        update_in(state.counts.graphql_cost, &(&1 + cost))

      _ ->
        state
    end
  end

  defp blocked_until(state, key), do: get_in(state.limits, [key, :blocked_until]) || 0
  defp header(response, key), do: response |> Map.get(:headers, %{}) |> Map.get(key) |> List.wrap() |> List.first()

  defp integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp integer(_), do: nil
end
