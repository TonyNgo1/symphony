defmodule SymphonyElixir.GitHub.Client do
  @moduledoc """
  GitHub Projects v2 statuses with native issue dependencies and hierarchy.
  Reads fail closed: incomplete project/relationship data never dispatches work.
  """
  alias SymphonyElixir.Config
  alias SymphonyElixir.GitHub.Completion
  alias SymphonyElixir.GitHub.Http
  alias SymphonyElixir.GitHub.Relationships
  alias SymphonyElixir.Tracker.Issue

  @api_version "2026-03-10"
  @active_states ["Ready", "In progress", "In review", "Integrating"]
  @states ["Backlog", "Ready", "In progress", "In review", "Integrating", "Human Review", "Done"]

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker) do
    with {:ok, _} <- settings(tracker), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker) do
    extra =
      case Map.get(tracker, :provider, %{})["token"] do
        "$" <> name -> [name]
        _ -> []
      end

    Enum.uniq(["GITHUB_TOKEN", "GH_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_ENTERPRISE_TOKEN"] ++ extra)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states),
    do: fetch_issues_by_states_for_test(states, Config.settings!().tracker, &perform_request/5)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(ids),
    do: fetch_issues_by_ids_for_test(ids, Config.settings!().tracker, &perform_request/5)

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(states, tracker, request_fun) do
    with {:ok, config} <- settings(tracker),
         {:ok, _field, items} <- project_context(config, request_fun) do
      items
      |> Map.values()
      |> Enum.filter(&(&1.state in states and required_labels?(&1, tracker)))
      |> load_issues(items, config, request_fun)
    end
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test([], _tracker, _fun), do: {:ok, []}

  def fetch_issues_by_ids_for_test(ids, tracker, request_fun) do
    with {:ok, numbers} <- parse_numbers(ids),
         {:ok, config} <- settings(tracker),
         {:ok, _field, items} <- project_context(config, request_fun) do
      numbers |> Enum.flat_map(&List.wrap(items[&1])) |> load_issues(items, config, request_fun)
    end
  end

  @spec update_project_status(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_project_status(identifier, status, opts \\ []) do
    {tracker, request_fun} = options(opts)

    with {:ok, number} <- parse_number(identifier),
         {:ok, config} <- settings(tracker),
         {:ok, field, items} <- project_context(config, request_fun),
         %{state: current} = item <- items[number] || {:error, :github_project_item_not_found},
         :ok <- authorize_transition(Keyword.get(opts, :issue), number, current, status),
         :ok <- completion_transition(item, items, status, config, request_fun, opts),
         %{} = option <-
           Enum.find(field["options"], &(name(&1["name"]) == status)) ||
             {:error, :github_project_status_not_found},
         {:ok, payload} <- patch_status(item, field, option, config, request_fun) do
      {:ok, %{"issue_identifier" => identifier, "status" => status, "payload" => payload}}
    end
  end

  defp completion_transition(item, items, status, config, request_fun, opts) do
    issue = Keyword.fetch!(opts, :issue)
    review_pass = issue.state == "In review" and (status == "Integrating" or (status == "Human Review" and Keyword.has_key?(opts, :evidence)))

    cond do
      review_pass or status == "Done" ->
        verify_completion(item, items, status, config, request_fun, opts)

      status in ["In progress", "In review"] ->
        save_review(issue.identifier, nil, opts)

      true ->
        :ok
    end
  end

  defp verify_completion(item, items, status, config, request_fun, opts) do
    get = fn suffix ->
      uri = URI.parse(suffix)
      api("GET", repo_path(config) <> uri.path, URI.decode_query(uri.query || ""), nil, config, request_fun)
    end

    with {:ok, issue} <- load_issue(item, items, config, request_fun),
         true <- issue.dispatchable or item.state == "Done",
         {:ok, %{"body" => body}} <- get.("/issues/#{issue.id}") do
      verify_evidence(%{issue | description: body}, status, get, opts)
    else
      {:error, _} = error -> error
      _ -> {:error, :github_issue_not_dispatchable}
    end
  end

  defp verify_evidence(issue, "Done", get, opts) do
    with {:ok, pad} <- workpad(issue.identifier, nil, opts),
         do: Completion.finish(issue, Keyword.get(opts, :evidence), Completion.read_record(pad["body"]), get)
  end

  defp verify_evidence(issue, _status, get, opts) do
    with {:ok, record} <- Completion.review(issue, Keyword.get(opts, :evidence), get),
         do: save_review(issue.identifier, record, opts)
  end

  defp save_review(identifier, record, opts) do
    with {:ok, pad} <- workpad(identifier, nil, opts),
         {:ok, _} <- workpad(identifier, pad["body"] || "## Agent Workpad\n", Keyword.put(opts, :review_record, record)),
         do: :ok
  end

  defp patch_status(item, field, option, config, request_fun) do
    body = %{"fields" => [%{"id" => field["id"], "value" => option["id"]}]}
    api("PATCH", project_path(config) <> "/items/#{item.id}", %{}, body, config, request_fun)
  end

  # Human Review cannot be exited by an agent. A human moves the card in GitHub.
  # Bind transitions to the worker's issue and role, including idempotent retries.
  defp authorize_transition(%Issue{} = issue, number, current, target) do
    cond do
      issue.id != to_string(number) -> {:error, :github_wrong_issue}
      current == "Human Review" -> {:error, :github_human_review_pause}
      current == "Ready" and target == "In review" -> {:error, :github_invalid_transition}
      target not in allowed_transitions(issue) -> {:error, :github_invalid_transition}
      not current_worker?(issue, current, target) -> {:error, :github_stale_worker}
      true -> :ok
    end
  end

  defp authorize_transition(nil, _number, _current, _target), do: {:error, :github_issue_context_required}

  defp allowed_transitions(%{state: "Ready"}), do: ["In progress", "In review", "Human Review"]
  defp allowed_transitions(%{state: "In progress"}), do: ["In review", "Human Review"]
  defp allowed_transitions(%{state: "Integrating"}), do: ["Done", "In progress", "Human Review"]

  defp allowed_transitions(%{state: "In review", labels: labels}) do
    if "type:feature" in labels, do: ["In progress", "Human Review"], else: ["In progress", "Integrating", "Human Review"]
  end

  defp allowed_transitions(_), do: []

  defp current_worker?(issue, current, target),
    do: current in [issue.state, target] or (issue.state == "Ready" and current == "In progress")

  @spec workpad(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def workpad(identifier, body, opts \\ []) do
    {tracker, request_fun} = options(opts)

    with {:ok, number} <- parse_number(identifier),
         {:ok, config} <- settings(tracker),
         :ok <- validate_workpad(body),
         {:ok, comments} <- list_all(issue_path(config, number) <> "/comments", %{}, config, request_fun) do
      matches = Enum.filter(comments, &String.starts_with?(&1["body"] || "", "## Agent Workpad"))

      case {matches, body} do
        {[], nil} -> {:ok, %{"body" => nil}}
        {[comment], nil} -> {:ok, Map.take(comment, ["id", "body", "html_url"])}
        {[], text} -> write_workpad("POST", issue_path(config, number) <> "/comments", text, nil, config, request_fun, opts)
        {[comment], text} -> write_workpad("PATCH", repo_path(config) <> "/issues/comments/#{comment["id"]}", text, comment["body"], config, request_fun, opts)
        _ -> {:error, :github_duplicate_workpads}
      end
    end
  end

  defp write_workpad(method, path, text, previous, config, request_fun, opts) do
    body = Completion.preserve_record(text, previous, opts)
    with :ok <- validate_workpad(body), do: api(method, path, %{}, %{"body" => body}, config, request_fun)
  end

  defp validate_workpad(nil), do: :ok

  defp validate_workpad(body) when is_binary(body) do
    if String.starts_with?(body, "## Agent Workpad\n") and length(String.split(body, "\n")) <= 40, do: :ok, else: {:error, :github_invalid_workpad}
  end

  defp validate_workpad(_), do: {:error, :github_invalid_workpad}

  @spec request(String.t(), String.t(), map(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def request(method, path, params, body, opts \\ []) do
    {tracker, request_fun} = options(opts)
    with {:ok, config} <- settings(tracker), do: request_fun.(method, path, params, body, config)
  end

  defp options(opts),
    do: {
      Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end),
      Keyword.get(opts, :request_fun, &perform_request/5)
    }

  defp project_context(config, request_fun) do
    with {:ok, fields} <- list_all(project_path(config) <> "/fields", %{}, config, request_fun),
         %{} = field <-
           Enum.find(fields, &(&1["name"] == config.status_field and &1["data_type"] == "single_select")) ||
             {:error, :github_project_status_field_not_found},
         :ok <- validate_options(field),
         {:ok, model_fields} <- model_fields(fields, config),
         {:ok, raw_items} <- project_items(config, [field | Map.values(model_fields)], request_fun) do
      items =
        for item <- raw_items,
            item["content_type"] == "Issue",
            is_nil(item["archived_at"]),
            raw = item["content"],
            is_map(raw),
            is_nil(raw["pull_request"]),
            same_repo?(raw, config),
            is_integer(raw["number"]),
            into: %{} do
          status = Enum.find(item["fields"] || [], &(&1["id"] == field["id"]))
          selection = selected_values(item, model_fields)

          {raw["number"], Map.merge(%{id: item["id"], raw: raw, state: status_name(status, field)}, selection)}
        end

      {:ok, field, items}
    end
  end

  defp project_items(config, fields, request_fun) do
    params = %{"q" => "repo:#{config.repo}", "fields" => Enum.map_join(fields, ",", &to_string(&1["id"]))}
    list_all(project_path(config) <> "/items", params, config, request_fun)
  end

  defp model_fields(fields, config) do
    names = [model: config.model_field, reasoning_effort: config.reasoning_effort_field]

    Enum.reduce_while(names, {:ok, %{}}, fn {key, name}, {:ok, acc} ->
      case Enum.filter(fields, &(&1["name"] == name)) do
        [] -> {:cont, {:ok, acc}}
        [%{"data_type" => "single_select", "options" => options} = field] when is_list(options) -> {:cont, {:ok, Map.put(acc, key, field)}}
        _ -> {:halt, {:error, {:github_invalid_model_field, name}}}
      end
    end)
  end

  defp selected_values(item, fields), do: Map.new(fields, fn {key, definition} -> {key, selected_value(item, definition)} end)

  defp selected_value(_item, nil), do: nil

  defp selected_value(item, field) do
    case Enum.find(item["fields"] || [], &(&1["id"] == field["id"])) do
      nil -> nil
      %{"value" => nil} -> nil
      value -> status_name(value, field) || "<invalid #{field["name"]} selection>"
    end
  end

  @doc "Planner-only operation. Validate exact Project options before writing either field."
  @spec update_model_selection(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_model_selection(identifier, selection, opts \\ []) do
    {tracker, request_fun} = options(opts)

    with true <- is_nil(Keyword.get(opts, :issue)),
         true <- is_map(selection) and map_size(selection) > 0 and Enum.all?(Map.keys(selection), &(&1 in [:model, :reasoning_effort])),
         {:ok, number} <- parse_number(identifier),
         {:ok, config} <- settings(tracker),
         {:ok, fields} <- list_all(project_path(config) <> "/fields", %{}, config, request_fun),
         {:ok, definitions} <- model_fields(fields, config),
         {:ok, values} <- selection_values(selection, definitions),
         {:ok, _, items} <- project_context(config, request_fun),
         %{} = item <- items[number] || {:error, :github_project_item_not_found},
         {:ok, _} <- api("PATCH", project_path(config) <> "/items/#{item.id}", %{}, %{"fields" => values}, config, request_fun),
         {:ok, _, updated} <- project_context(config, request_fun),
         %{} = updated_item <- updated[number] || {:error, :github_project_item_not_found},
         true <- Enum.all?(selection, fn {key, value} -> Map.get(updated_item, key) == value end) do
      {:ok, Map.take(updated_item, [:model, :reasoning_effort])}
    else
      {:error, _} = error -> error
      _ -> {:error, :github_model_selection_not_verified}
    end
  end

  defp selection_values(selection, definitions) do
    Enum.reduce_while(selection, {:ok, []}, fn {key, value}, {:ok, acc} ->
      field = definitions[key]
      option = field && Enum.find(field["options"], &(name(&1["name"]) == value))

      if field && (is_nil(value) or (is_binary(value) and option)),
        do: {:cont, {:ok, [%{"id" => field["id"], "value" => if(option, do: option["id"], else: nil)} | acc]}},
        else: {:halt, {:error, {:github_model_option_not_found, key, value}}}
    end)
  end

  defp validate_options(%{"options" => options}) when is_list(options) do
    if Enum.all?(@states, fn state -> Enum.any?(options, &(name(&1["name"]) == state)) end), do: :ok, else: {:error, :github_missing_workflow_statuses}
  end

  defp validate_options(_), do: {:error, :github_missing_workflow_statuses}

  defp status_name(nil, _), do: nil

  defp status_name(field, definition) do
    value = field["value"]
    id = if is_map(value), do: value["id"], else: value

    case Enum.find(definition["options"], &(&1["id"] == id)) do
      nil -> name(value)
      option -> name(option["name"])
    end
  end

  defp load_issues(selected, items, config, request_fun) do
    with {:ok, relationships} <- Relationships.fetch(selected, config, request_fun) do
      load_selected_issues(selected, items, config, request_fun, relationships)
    end
  end

  defp required_labels?(item, tracker) do
    required = Map.get(tracker, :required_labels, [])
    names = labels(item.raw)
    Enum.all?(required, &(String.downcase(String.trim(&1)) in names))
  end

  defp load_selected_issues(selected, items, config, request_fun, relationships) do
    Enum.reduce_while(selected, {:ok, []}, fn item, {:ok, acc} ->
      result =
        case relationships[item.raw["number"]] do
          :rest -> load_issue(item, items, config, request_fun)
          related -> normalize_related_issue(item, items, config, related)
        end

      case result do
        {:ok, issue} -> {:cont, {:ok, [issue | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp load_issue(item, items, config, request_fun) do
    number = item.raw["number"]
    path = issue_path(config, number)

    with {:ok, blockers} <- list_all(path <> "/dependencies/blocked_by", %{}, config, request_fun),
         {:ok, children} <- list_all(path <> "/sub_issues", %{}, config, request_fun),
         {:ok, parent} <- api("GET", path <> "/parent", %{}, nil, config, request_fun, true) do
      normalize_related_issue(item, items, config, %{blockers: blockers, children: children, parent: parent})
    end
  end

  defp normalize_related_issue(item, items, config, %{blockers: blockers, children: children, parent: parent}) do
    number = item.raw["number"]
    feature? = "type:feature" in labels(item.raw)
    parent_ref = if is_map(parent), do: relationship(parent, items, config), else: nil
    child_refs = Enum.map(children, &relationship(&1, items, config))
    blocker_refs = Enum.map(blockers, &relationship(&1, items, config))

    hierarchy_ready = hierarchy_ready?(item, parent, parent_ref, child_refs, config)

    issue = normalize_issue(item.raw, config.repo, item)

    {:ok,
     %{
       issue
       | branch_name: "#{if feature?, do: "feature", else: "task"}/GH-#{number}",
         blocked_by: Enum.map(blocker_refs, &%{id: to_string(&1["number"]), identifier: &1["identifier"], state: &1["state"]}),
         native_ref: Map.merge(issue.native_ref, %{"parent" => parent_ref, "children" => child_refs}),
         dispatchable: issue.dispatchable and hierarchy_ready and Enum.all?(blocker_refs, & &1["done"])
     }}
  end

  defp hierarchy_ready?(item, parent, parent_ref, children, config) do
    case {"type:feature" in labels(item.raw), "type:task" in labels(item.raw)} do
      {true, false} -> item.state == "Ready" or (children != [] and Enum.all?(children, &integrated_child?(&1, config)))
      {false, true} -> valid_parent?(parent, parent_ref, config)
      _ -> false
    end
  end

  defp integrated_child?(child, config) do
    child["in_project"] and child["state"] == "Done" and
      String.downcase(child["repo"]) == String.downcase(config.repo) and "type:task" in child["labels"]
  end

  defp valid_parent?(parent, %{"repo" => repo, "state" => "In progress"}, config),
    do: String.downcase(repo) == String.downcase(config.repo) and "type:feature" in labels(parent)

  defp valid_parent?(_parent, _ref, _config), do: false

  defp relationship(raw, items, config) do
    same_repo = same_repo?(raw, config)
    item = if same_repo, do: items[raw["number"]], else: nil
    # Project status is authoritative for managed items. Outside the project,
    # only a natively closed issue resolves a dependency.
    state = if item, do: item.state, else: raw["state"]

    %{
      "number" => raw["number"],
      "identifier" => "GH-#{raw["number"]}",
      "repo" => issue_repo(raw),
      "state" => state,
      "url" => raw["html_url"],
      "in_project" => not is_nil(item),
      "labels" => labels(raw),
      "done" => if(item, do: state == "Done", else: state == "closed")
    }
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t()) :: Issue.t()
  def normalize_issue_for_test(raw, repo), do: normalize_issue(raw, repo, %{id: nil, state: raw["state"]})

  defp normalize_issue(raw, repo, item) do
    %Issue{
      id: to_string(raw["number"]),
      identifier: "GH-#{raw["number"]}",
      title: raw["title"],
      description: raw["body"],
      state: item.state,
      model: Map.get(item, :model),
      reasoning_effort: Map.get(item, :reasoning_effort),
      url: raw["html_url"],
      labels: labels(raw),
      assignee_id: get_in(raw, ["assignee", "login"]),
      native_ref: %{"id" => raw["id"], "node_id" => raw["node_id"], "number" => raw["number"], "repo" => repo, "project_item_id" => item.id},
      dispatchable: item.state in @active_states and raw["state"] == "open" and is_nil(raw["pull_request"]),
      created_at: datetime(raw["created_at"]),
      updated_at: datetime(raw["updated_at"])
    }
  end

  defp labels(raw),
    do:
      Enum.map(raw["labels"] || [], fn label ->
        if(is_map(label), do: label["name"], else: label) |> String.trim() |> String.downcase()
      end)

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, result, _} -> result
      _ -> nil
    end
  end

  defp datetime(_), do: nil
  defp name(%{"raw" => value}), do: value
  defp name(%{"name" => value}), do: name(value)
  defp name(value) when is_binary(value), do: value
  defp name(_), do: nil

  defp issue_repo(raw) do
    raw |> Map.get("repository_url", "") |> URI.parse() |> Map.get(:path, "") |> String.replace_prefix("/repos/", "")
  end

  defp same_repo?(raw, config), do: String.downcase(issue_repo(raw)) == String.downcase(config.repo)

  # Both Project cursor pagination and standard REST page pagination use Link.
  # Never follow a supplied host: extract only the query for the original path.
  defp list_all(path, params, config, request_fun, seen \\ []) do
    params = Map.put(params, "per_page", 100)

    with false <- params in seen,
         {:ok, %{status: 200, body: body} = response} <- request_fun.("GET", path, params, nil, config),
         true <- is_list(body) do
      append_pages(body, next_params(response), path, config, request_fun, [params | seen])
    else
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, _} = error -> error
      _ -> {:error, :github_invalid_pagination_payload}
    end
  end

  defp append_pages(body, nil, _path, _config, _fun, _seen), do: {:ok, body}

  defp append_pages(body, next, path, config, fun, seen) do
    with {:ok, rest} <- list_all(path, next, config, fun, seen), do: {:ok, body ++ rest}
  end

  defp next_params(response) do
    links = Map.get(response, :headers, %{}) |> Map.get("link", []) |> List.wrap() |> Enum.join(",")

    case Regex.run(~r/<([^>]+)>;\s*rel="next"/, links) do
      [_, url] -> URI.decode_query(URI.parse(url).query || "")
      _ -> nil
    end
  end

  defp api(method, path, params, body, config, fun, allow_missing \\ false) do
    case fun.(method, path, params, body, config) do
      {:ok, %{status: status, body: payload}} when status in 200..299 -> {:ok, payload}
      {:ok, %{status: 404}} when allow_missing -> {:ok, nil}
      {:ok, %{status: status}} -> {:error, {:github_api_status, status}}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :github_unknown_payload}
    end
  end

  defp perform_request(method, path, params, body, config) do
    methods = %{"GET" => :get, "POST" => :post, "PATCH" => :patch, "PUT" => :put, "DELETE" => :delete}

    opts = [
      method: methods[method],
      url: config.api_url <> path,
      params: params,
      headers: [{"accept", "application/vnd.github+json"}, {"authorization", "Bearer #{config.token}"}, {"x-github-api-version", @api_version}, {"user-agent", "symphony"}],
      connect_options: [timeout: 30_000]
    ]

    opts = if is_nil(body), do: opts, else: Keyword.put(opts, :json, body)

    case Http.request(opts) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body, headers: response.headers}}
      {:error, reason} -> {:error, {:github_api_request, reason}}
    end
  end

  defp settings(tracker) do
    provider = Map.get(tracker, :provider, %{})
    repo = resolve(provider["repo"], System.get_env("GITHUB_REPO"))
    token = resolve(provider["token"], System.get_env("GITHUB_TOKEN"))
    api_url = provider["api_url"] || "https://api.github.com"
    project_number = provider["project_number"]
    owner = resolve(provider["project_owner"], if(is_binary(repo), do: hd(String.split(repo, "/"))))
    type = provider["project_owner_type"] || "user"

    checks = [
      {present?(repo), :missing_github_repo},
      {matches?(repo, ~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/), :invalid_github_repo},
      {present?(token), :missing_github_token},
      {valid_api_url?(api_url), :invalid_github_api_url},
      {is_integer(project_number) and project_number > 0, :missing_github_project_number},
      {matches?(owner, ~r/^[A-Za-z0-9_.-]+$/), :invalid_github_project_owner},
      {type in ["user", "organization"], :invalid_github_project_owner_type}
    ]

    case Enum.find(checks, fn {valid?, _} -> not valid? end) do
      {false, error} ->
        {:error, error}

      nil ->
        {:ok,
         %{
           repo: repo,
           token: token,
           api_url: String.trim_trailing(api_url, "/"),
           project_number: project_number,
           project_owner: owner,
           project_owner_type: type,
           status_field: provider["status_field"] || "Status",
           model_field: field_name(provider, "model_field", "Model"),
           reasoning_effort_field: field_name(provider, "reasoning_effort_field", "Reasoning effort")
         }}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp field_name(provider, key, default), do: provider[key] || default
  defp matches?(value, regex), do: is_binary(value) and Regex.match?(regex, value)

  defp valid_api_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} -> present?(host)
      _ -> false
    end
  end

  defp valid_api_url?(_), do: false

  defp resolve(nil, fallback), do: fallback
  defp resolve("$" <> env, _), do: System.get_env(env)
  defp resolve(value, _), do: value

  defp project_path(config) do
    kind = if config.project_owner_type == "user", do: "users", else: "orgs"
    "/#{kind}/#{config.project_owner}/projectsV2/#{config.project_number}"
  end

  defp repo_path(config), do: "/repos/#{config.repo}"
  defp issue_path(config, number), do: repo_path(config) <> "/issues/#{number}"
  defp parse_number("GH-" <> number), do: parse_number(number)

  defp parse_number(number) when is_binary(number) do
    case Integer.parse(number) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, :invalid_github_issue_id}
    end
  end

  defp parse_number(_), do: {:error, :invalid_github_issue_id}

  defp parse_numbers(ids) do
    Enum.reduce_while(Enum.uniq(ids), {:ok, []}, fn id, {:ok, acc} ->
      case parse_number(id) do
        {:ok, number} -> {:cont, {:ok, [number | acc]}}
        error -> {:halt, error}
      end
    end)
  end
end
