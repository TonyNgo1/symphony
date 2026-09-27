defmodule SymphonyElixir.WorkerRecovery do
  @moduledoc "Durable local GitHub worker handoffs and bounded recovery, outside disposable workspaces."
  alias SymphonyElixir.{Config, PathSafety, WorkspaceFingerprint}
  alias SymphonyElixir.GitHub.Client

  @spec context(map(), term()) :: map() | nil
  def context(issue, host \\ nil) do
    policy = Config.settings!().agent

    if policy.recovery_enabled and is_nil(host) and is_map(issue.native_ref) and is_binary(issue.native_ref["repo"]) do
      key = :crypto.hash(:sha256, String.downcase(issue.native_ref["repo"]) <> ":" <> issue.id) |> Base.encode16(case: :lower)
      %{issue: issue, policy: policy, path: Path.join([Config.local_workspace_root(), ".symphony-recovery", key <> ".json"])}
    end
  end

  def prepare(context, client \\ Client)
  @spec prepare(map() | nil, module()) :: :ok | {:error, term()}
  def prepare(nil, _client), do: :ok

  def prepare(context, client) do
    state = read!(context)

    cond do
      live_owner?(state) ->
        {:error, :recovery_worker_still_running}

      state["pause_applied"] ->
        write!(context, reset(state))
        :ok

      true ->
        prepare_state(context, recover_interrupted(state, context.issue), client)
    end
  rescue
    _ -> {:error, :recovery_state_unavailable}
  end

  @spec observe(map() | nil) :: :ok
  def observe(nil), do: :ok

  def observe(%{issue: %{state: "Human Review"}} = context) do
    state = read!(context)
    if state["paused"], do: write!(context, Map.put(state, "pause_applied", true))
    :ok
  rescue
    _ -> :ok
  end

  def observe(_), do: :ok

  @spec start!(map() | nil) :: :ok
  def start!(nil), do: :ok

  def start!(context) do
    state = read!(context)
    if live_owner?(state), do: raise("Recovery worker already owns this issue")
    previous = if state["latest"], do: [state["latest"] | state["attempts"]], else: state["attempts"]
    latest = %{"role" => context.issue.state, "started_at" => now(), "checkpoint_turn" => 0}
    write!(context, Map.merge(state, %{"active" => true, "owner" => self() |> :erlang.pid_to_list() |> List.to_string(), "vm" => vm(), "latest" => latest, "attempts" => Enum.take(previous, 19)}))
  end

  @spec workspace!(map() | nil, Path.t()) :: :ok
  def workspace!(nil, _workspace), do: :ok

  def workspace!(context, workspace) do
    update_latest!(context, %{"workspace" => workspace, "baseline" => WorkspaceFingerprint.capture(workspace)})
  end

  @spec session!(map() | nil, map()) :: :ok
  def session!(nil, _session), do: :ok
  def session!(context, session), do: update_latest!(context, %{"thread_id" => session.thread_id, "workspace" => session.workspace})

  @spec checkpoint!(map() | nil, String.t(), pos_integer()) :: :ok
  def checkpoint!(nil, _body, _turn), do: :ok

  def checkpoint!(context, body, turn) do
    state = read!(context)
    snapshot = WorkspaceFingerprint.capture(state["latest"]["workspace"])
    latest = Map.merge(state["latest"], %{"workpad" => body, "checkpoint_at" => now(), "checkpoint_turn" => turn, "snapshot" => snapshot})
    write!(context, %{state | "latest" => latest, "workpad" => body})
  end

  @spec checkpoint_due?(map() | nil, pos_integer(), pos_integer()) :: boolean()
  def checkpoint_due?(nil, _turn, _max), do: false

  def checkpoint_due?(context, turn, max_turns) do
    (rem(turn, context.policy.checkpoint_interval_turns) == 0 or turn == max_turns) and read!(context)["latest"]["checkpoint_turn"] != turn
  end

  def finish!(context, outcome, refreshed \\ nil)
  @spec finish!(map() | nil, :ok | :failed | :quota | :blocked, map() | nil) :: :ok
  def finish!(nil, _outcome, _refreshed), do: :ok

  def finish!(context, outcome, refreshed) do
    state = read!(context)
    state = finish_state(state, outcome, refreshed)
    latest = Map.merge(state["latest"], %{"finished_at" => now(), "outcome" => to_string(outcome)})
    write!(context, %{state | "active" => false, "latest" => latest})
  end

  @spec read!(map()) :: map()
  def read!(context) do
    safe_path!(context.path)

    case File.read(context.path) do
      {:error, :enoent} ->
        empty(context.issue)

      {:ok, json} ->
        state = Jason.decode!(json)
        unless valid?(state), do: raise("Invalid recovery state")
        state

      _ ->
        raise "Cannot read recovery state"
    end
  end

  defp prepare_state(context, state, client) do
    reason = state["paused"] || limit_reason(state, context.policy)

    if reason do
      state = Map.put(state, "paused", reason)
      write!(context, state)

      case publish_pause(context, state, client) do
        :ok -> write!(context, Map.put(state, "pause_applied", true))
        _ -> :ok
      end

      {:error, {:worker_recovery_pause, reason}}
    else
      write!(context, state)
      :ok
    end
  end

  defp publish_pause(context, state, client) do
    identifier = context.issue.identifier
    opts = [issue: context.issue]

    with {:ok, pad} <- client.workpad(identifier, nil, opts),
         body = pause_body(pad["body"], state, context.path),
         {:ok, _} <- client.workpad(identifier, body, Keyword.put(opts, :review_record, nil)),
         {:ok, _} <- client.update_project_status(identifier, "Human Review", opts) do
      :ok
    end
  end

  defp pause_body(body, state, path) do
    lines = (body || "## Agent Workpad\n") |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, ["Review: ", "Blockers:", "Recovery:"])) |> Enum.take(37)
    thread = get_in(state, ["latest", "thread_id"]) || "not started"
    Enum.join(lines ++ ["Blockers: Symphony paused: #{state["paused"]}. Human must inspect and move to Ready/In progress/In review when resolved.", "Recovery: #{path}; Codex task #{thread}"], "\n")
  end

  defp finish_state(state, :failed, _), do: Map.update!(state, "failures", &(&1 + 1))
  defp finish_state(state, outcome, _) when outcome in [:quota, :blocked], do: state

  defp finish_state(state, :ok, refreshed) do
    latest = state["latest"]
    snapshot = WorkspaceFingerprint.capture(latest["workspace"])
    changed_phase = is_map(refreshed) and phase(refreshed.state) != phase(latest["role"])
    progress = snapshot["fingerprint"] != latest["baseline"]["fingerprint"] or changed_phase
    rework = is_map(refreshed) and latest["role"] in ["In review", "Integrating"] and refreshed.state == "In progress"

    state
    |> Map.put("failures", 0)
    |> Map.put("no_progress", if(progress, do: 0, else: state["no_progress"] + 1))
    |> Map.put("reworks", state["reworks"] + if(rework, do: 1, else: 0))
    |> put_in(["latest", "snapshot"], snapshot)
  end

  defp limit_reason(state, policy) do
    cond do
      state["failures"] >= policy.max_consecutive_failures -> "consecutive worker failures"
      state["no_progress"] >= policy.max_no_progress_runs -> "worker runs without repository progress"
      state["reworks"] >= policy.max_rework_cycles -> "repeated review/integration rework"
      true -> nil
    end
  end

  defp recover_interrupted(%{"active" => true} = state, issue) do
    role = state["latest"]["role"]
    same_phase = phase(role) == phase(issue.state)
    rework = role in ["In review", "Integrating"] and issue.state == "In progress"

    state
    |> Map.put("active", false)
    |> Map.update!("failures", &(&1 + if(same_phase, do: 1, else: 0)))
    |> Map.update!("reworks", &(&1 + if(rework, do: 1, else: 0)))
    |> update_in(["latest"], &Map.merge(&1, %{"finished_at" => now(), "outcome" => "interrupted"}))
  end

  defp recover_interrupted(state, _issue), do: state
  defp reset(state), do: Map.merge(state, %{"failures" => 0, "no_progress" => 0, "reworks" => 0, "paused" => nil, "pause_applied" => false, "active" => false})
  defp phase(state) when state in ["Ready", "In progress"], do: :implementation
  defp phase(state), do: state

  defp empty(issue),
    do: %{
      "version" => 1,
      "identifier" => issue.identifier,
      "repo" => issue.native_ref["repo"],
      "failures" => 0,
      "no_progress" => 0,
      "reworks" => 0,
      "paused" => nil,
      "pause_applied" => false,
      "active" => false,
      "attempts" => [],
      "latest" => nil,
      "workpad" => nil
    }

  defp valid?(%{"version" => 1, "attempts" => attempts, "active" => active} = state),
    do:
      is_list(attempts) and is_boolean(active) and is_boolean(state["pause_applied"]) and
        Enum.all?(["paused", "latest", "workpad"], &Map.has_key?(state, &1)) and
        Enum.all?(["failures", "no_progress", "reworks"], &(is_integer(state[&1]) and state[&1] >= 0))

  defp valid?(_), do: false

  defp live_owner?(%{"active" => true, "vm" => vm, "owner" => owner}) do
    vm == vm() and owner |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
  rescue
    _ -> false
  end

  defp live_owner?(_), do: false
  defp vm, do: "#{System.pid()}:#{:erlang.system_info(:start_time)}"
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp update_latest!(context, values), do: write!(context, update_in(read!(context), ["latest"], &Map.merge(&1, values)))

  defp write!(context, state) do
    safe_path!(context.path)
    File.mkdir_p!(Path.dirname(context.path))
    temporary = context.path <> ".#{System.unique_integer([:positive])}.tmp"
    safe_path!(temporary)
    File.write!(temporary, Jason.encode!(state, pretty: true))
    File.rename!(temporary, context.path)
    :ok
  end

  defp safe_path!(path) do
    {:ok, canonical} = PathSafety.canonicalize(path)
    unless String.downcase(canonical) == String.downcase(Path.expand(path)), do: raise("Recovery path contains a link")
  end
end
