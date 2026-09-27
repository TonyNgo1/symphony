# Symphony Elixir

GitHub Projects can supply optional single-select `Model` and `Reasoning effort`
fields. `codex.model` and `codex.reasoning_effort` are implementation defaults;
`review_model` / `review_reasoning_effort` and `integration_model` /
`integration_reasoning_effort` under `codex` select fresh review/integration workers.
For issues labeled `type:feature`, `parent_review_model` and
`parent_review_reasoning_effort` override the review settings independently;
missing/blank values fall back to review settings, then global settings. The ArtCom
workflow uses high effort throughout, Sol for child reviews, Astra for parent
reviews, and Sol for integration. Its planner reserves Luna for the simplest
mechanical changes with an established pattern and automated check, uses Sol for
small clear implementations, and Astra for architecture, ambiguity or subtle
correctness. Existing explicit Project effort overrides must be set to high or
cleared before releasing work under this policy.
Settings are validated against `model/list` and pinned for a worker's lifetime.
Invalid selections block only the affected issue until corrected or restarted.
`mix github.models GH-123 --model <id> --effort <value>` validates, writes and reads
back Project selections without starting Symphony. With no flags it reads them;
`--clear-model --clear-effort` restores defaults. Requires `GITHUB_TOKEN` and an
existing Project field/option setup. See ArtCom's `docs/SYMPHONY_MODELS.md` for the
complete operator/planner workflow. The no-op harness supports `--model-routing`.
The planner command initializes its GitHub HTTP service and reloads the selected
workflow without starting the scheduler.

For native Windows tests, put Git Bash on PATH and provide Windows PowerShell and
Python 3 (`py`). The suite compiles a temporary native shell-fixture launcher using
PowerShell's built-in C# compiler and uses directory junctions for link-safety tests;
no administrator privileges are needed. Run `mix test --cover` for the full offline
suite. The existing coverage scope/100% threshold is unchanged; live tracker tests
remain explicitly opt-in. The verified Windows run has 358 tests, zero failures,
six live tests skipped, and passes the configured coverage gate.

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls the configured tracker for candidate work (included adapters: Linear, GitHub Issues, Jira
   Cloud, Asana, and GitLab)
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, the selected tracker adapter may advertise provider-native tools. The
Linear serves `linear_graphql`, GitHub serves `github_api`, `set_project_status` and `agent_workpad`, Jira Cloud serves
`jira_rest`, Asana serves `asana_api`, and GitLab serves `gitlab_api`. Symphony executes those
tools with configured host-side auth and removes declared tracker-token environment variables from
the Codex child, so the agent does not need a second tracker login.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces unless
`workspace.retain_terminal: true` is configured.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
tracker issue can become a dispatch candidate again after restart.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Burrito releases

Symphony ships self-contained executables built with
[Burrito](https://github.com/burrito-elixir/burrito). They embed Erlang/OTP, Elixir, and Symphony,
but still expect `codex`, `git`, and the selected tracker credentials on the target machine.

Supported release targets:

- `macos_arm64`
- `macos_x86_64`
- `linux_arm64`
- `linux_x86_64`

`v*` tags publish all four targets with checksums. A manual workflow run builds the same
artifacts without creating a release.

The `burrito-nightly` workflow builds each push to `main`, with no scheduled rebuilds.
After all four platform smoke tests pass, it updates the rolling
[`nightly` prerelease](https://github.com/openai/symphony/releases/tag/nightly),
including binaries and checksums. Nightly binaries use a `-nightly` version suffix;
the release notes identify the source commit. Stable releases remain unchanged.

After downloading the executable for your platform from a release:

```bash
chmod +x ./symphony-v0.0.1-macos_arm64
./symphony-v0.0.1-macos_arm64 ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  provider:
    project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on an issue from the configured tracker {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.kind` selects an adapter. Adapter-owned endpoint, scope, and auth settings belong under
  `tracker.provider`; the current Linear adapter still accepts the older flat `endpoint`,
  `api_key`, `project_slug`, and `assignee` aliases for compatibility.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.project_id` optionally assigns every new worker thread to an existing Codex project.
    Use the ID returned by `project/list` on the worker's app server; desktop tools may expose a
    different legacy ID. The ID is local to that server's Codex home. It does not change the issue
    workspace or sandbox. Omission preserves normal project behavior. A configured ID must be
    confirmed in the `thread/start` response before any agent turn starts. Unknown IDs or older
    servers that omit confirmation fail startup and follow ordinary worker retry/backoff.
    Workflow reloads affect new sessions only; existing tasks are never reassigned.
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- `codex.turn_timeout_ms` is the maximum silence interval while a turn is streaming. Each
  app-server update resets it; it is not a total turn runtime cap.
- Supported `codex.approval_policy` values depend on the targeted Codex app-server version. In the current local Codex schema, string values include `untrusted`, `on-failure`, `on-request`, and `never`, and object-form `reject` is also supported.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- When `codex.turn_sandbox_policy` is set explicitly, Symphony passes the map through to Codex
  unchanged. Compatibility then depends on the targeted Codex app-server version rather than local
  Symphony validation.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- For the Linear adapter, `tracker.provider.api_key` reads from `LINEAR_API_KEY` when unset or
  when value is `$LINEAR_API_KEY`. The legacy flat `tracker.api_key` alias behaves the same way.
- Do not put a literal tracker token in a repo-owned `WORKFLOW.md` if Codex can read that
  workspace. Use `$VAR`/host-side secret references so Symphony can keep the token out of the
  child environment.
- For path values, `~` is expanded to the home directory.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling,
  while `codex.command` stays a shell command string and any `$VAR` expansion there happens in the
  launched shell.

```yaml
tracker:
  provider:
    api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

### Linear adapter profile

- Config: use `tracker.kind: linear` with `tracker.provider.endpoint` (default
  `https://api.linear.app/graphql`), `api_key` (defaults to `LINEAR_API_KEY` and accepts
  `$VAR`), required `project_slug`, and optional `assignee` (a Linear user ID or `me`,
  defaulting to `LINEAR_ASSIGNEE`).
  The legacy flat `tracker.endpoint`, `api_key`, `project_slug`, and `assignee` aliases remain
  supported. `required_labels`, `active_states`, and `terminal_states` stay under `tracker`.
- Scope and paging: candidate reads filter the configured project slug and requested state names,
  following Linear pages of 50. ID refreshes are also project-scoped and batch up to 50 IDs. Empty
  state/ID lists return `{:ok, []}` without a Linear request.
- Identity and normalization: `issue.id` is the Linear issue ID and `issue.native_ref` is currently
  `nil`. Records missing a nonblank ID, identifier, title, or state are dropped from candidate
  pages and fail ID refreshes. State keeps Linear's spelling; integer priorities are preserved and
  other priority values become `nil`; RFC 3339 timestamps are parsed and unusable timestamps become
  `nil`. Labels are trimmed, lowercased, deduplicated, and blanks are dropped; blockers come from
  inverse `blocks` relations.
- Dispatchability: the adapter marks an issue dispatchable only when optional assignee routing
  matches and a `Todo` issue has no non-terminal blocker. The generic scheduler then applies
  active/terminal states, required labels, claims, retries, and concurrency.
- Tool: the Linear adapter advertises `linear_graphql`, accepting either a raw query string or an
  object with nonblank `query` and optional object `variables`. Symphony executes it host-side
  with the session-bound endpoint/token and strips declared token environment variables from the
  Codex child. `project_slug` scopes scheduler reads, not raw tool calls; the tool can access
  whatever the configured Linear token can access.
- Responsibility and errors: `linear_graphql` adds no idempotency key, retry, scope guard, or
  rate-limit policy, so workflows own idempotent mutations and handling provider errors. Read/config
  failures use `{:error, :missing_linear_api_token}`, `{:error, :missing_linear_project_slug}`,
  `{:error, :invalid_linear_endpoint}`, `{:error, :invalid_linear_assignee}`,
  `{:error, :missing_linear_viewer_identity}`, `{:error, {:linear_api_status, status}}`,
  `{:error, {:linear_api_request, reason}}`, `{:error, {:linear_graphql_errors, errors}}`,
  `{:error, :linear_unknown_payload}`, or `{:error, :linear_missing_end_cursor}`. Tool results
  are maps with `"success"`, JSON-string `"output"`, and text `"contentItems"`; invalid
  arguments, missing auth, and transport failures return `"success" => false` with
  `{"error": {"message": ...}}`, while top-level GraphQL errors preserve the response body with
  `"success" => false`.
  For portable reporting, map missing/invalid token, project, endpoint, assignee, or viewer errors
  to `tracker_config` or `tracker_auth`, request failures to `tracker_transport`, non-200 responses to
  `tracker_response` (`429` is `tracker_rate_limited`), GraphQL/unknown payload failures to
  `tracker_payload`, and missing cursors to `tracker_pagination`; logs and tool responses carry the
  human-readable provider detail.

### GitHub Issues adapter

- Config: `tracker.kind: github`, provider `repo` (`owner/repo`), `project_number` (positive integer),
  `token` (defaults to `GITHUB_TOKEN`, accepts `$VAR`), `project_owner` (defaults to repository owner),
  `project_owner_type` (`user` or `organization`), and `status_field` (default `Status`).
  Optional `api_url` defaults to `https://api.github.com` and requires HTTPS.
- Project statuses: Backlog, Ready, In progress, In review, Integrating, Human Review, Done.
  Only the middle four autonomous states dispatch. Done is terminal; Human Review is a hard pause.
  Native open/closed-only GitHub configurations are no longer supported by this fork.
- All managed issues need the configured required labels plus exactly one `type:feature` or
  `type:task` label. A task needs a native parent feature in the project and In progress.
  A Ready parent bootstraps its branch; other active parent states wait until all children are Done.
  Native blocked-by edges independently gate every active state. Never block parent bootstrap on children.
- All REST connections follow Link pagination. Project Status determines completion for managed blockers;
  native closed determines completion for blockers outside the project. Failed relationship reads fail closed.
- Scheduling batches native relationships through GraphQL (10 issues per request, 20 entries per
  connection). Truncated connections fall back to complete REST pagination for that issue;
  incomplete/error payloads never dispatch. Required labels are filtered before relationship reads.
- REST GETs use credential-scoped ETags and always revalidate with GitHub. No stale snapshot is
  served during failures. The in-memory cache holds at most 512 representations for five minutes;
  mutation attempts invalidate it. REST and GraphQL quota exhaustion suppress further requests
  for that credential/resource until reset; secondary limits back off across both resources.
  Requests already in flight can finish. Mutations are never automatically replayed by transport.
- `/api/v1/state.tracker_api` reports process-local request counts, conditional hits, GraphQL
  points, suppressed attempts and quota reset times. It excludes external GitHub clients and
  the harness controller. Cache, counters and GitHub backoff reset with the HTTP service.
- `github_api` is read-only. `set_project_status` binds changes to the current issue and worker role;
  workers cannot leave Human Review or send a reviewed parent directly to Integrating.
  `agent_workpad` reads/upserts one comment of at most 40 lines and rejects duplicate workpads.
- GitHub role changes end the worker; the next role starts a fresh thread in the same workspace.
  The prompt labels the parent's Project status supplied by the adapter. Fresh child
  implementation creates an absent task branch from the existing parent feature branch;
  review/integration treat a missing source branch as a blocker.
  Worker-initiated phase changes register their target before the status write.
  Reconciliation lets the tool response and turn finish before releasing the claim,
  with a 60-second bound for stuck handoffs. Unrelated state changes and quota stops
  still stop the worker immediately.
- Review approval requires passing validation evidence for the current source SHA;
  bug-labeled issues also require a permanent regression check with failed-before and
  passed-after evidence. The adapter owns the workpad's reserved `Review:` line.
- `Done` requires that saved review, an unchanged source head, passing validation for
  the exact remote target head, and GitHub-confirmed ancestry into the native parent's
  feature branch (children) or main (features). See WORKFLOW.md for the evidence schema.
  Every issue requires one `symphony-acceptance` JSON block (version 1, criteria).
  Approval and Done require exactly one passing acceptance entry per ID, at the
  respective commit. The protected review binds the entire acceptance contract;
  changed scope or validation policy requires fresh review. `github_check` criteria
  verify the remote check name, publisher app ID, exact SHA and successful completion.
  `review` criteria remain explicit reviewer attestations; the gate does not run local tests.
  Missing contracts and legacy review records fail closed; migrate approved scope and
  obtain a new review before continuing. See WORKFLOW.md for both evidence modes.
  Set `workspace.retain_terminal: true` for retained Done workspaces.
- Structured Codex quota errors immediately stop the failing worker and pause dispatch until the
  Symphony process restarts. This pause survives scheduler supervision restarts and workflow reloads.
- Opt-in `agent.recovery_enabled` adds local GitHub worker recovery. ArtCom enables it.
  `checkpoint_interval_turns`, `max_consecutive_failures`, `max_no_progress_runs`, and
  `max_rework_cycles` are positive integers, each defaulting to 3. Records live under
  the configured workspace root's `.symphony-recovery/`, outside individual clones.
  Every successful workpad write receives a runtime-owned `Worker:` line with task ID,
  role, workspace and recovery path; reserve that line plus the protected Review: line.
  Missing checkpoints trigger at most one extra checkpoint-only turn at each interval
  and before normal rotation. A refusal fails the attempt; quota errors get no extra turn.
  Limits persist across restarts and move the issue to Human Review, clearing old approval.
  If GitHub fails, a durable local pause blocks workers while publication retries.
  A human's release to an active state resets the limits. Repository snapshots include
  staged/unstaged/untracked content; workpad churn alone is not progress. Review rework
  remains cumulative even when implementation changes. Other trackers/SSH retain their behavior.
  Use `mix github.handoff GH-123 --workflow /path/to/WORKFLOW.md` with the same workspace
  environment as the launcher to inspect the latest attempt and 19 previous attempts.
  ArtCom's `run-symphony.ps1 -Handoff GH-123` loads that environment and works while the
  scheduler is running. The runtime saves IDs; it does not automatically resume human tasks.
- The ArtCom host launcher supports `-CheckOnly` for read-only configuration, board and prompt validation.
  The bundled WORKFLOW.md is the ArtCom example; the host repository's root workflow is authoritative.

### Jira Cloud adapter

- Config: use `tracker.kind: jira` with provider `base_url`, `email`, `api_token`, and required
  `project_key`; the first three default to `JIRA_BASE_URL`, `JIRA_EMAIL`, and `JIRA_API_TOKEN`
  and accept `$VAR`. Set explicit Jira-native `active_states` and `terminal_states`.
- Issues and reads: candidate reads and ID refreshes stay scoped to the configured project and
  requested statuses; `issue.id` is Jira's immutable ID and `issue.identifier` is the issue key.
- Blockers: inward `Blocks` links populate `blocked_by`; issues in Jira's `new` status category
  wait until blockers reach configured terminal states, while in-progress categories keep running.
- Tool: `jira_rest` sends relative `/rest/api/3/` requests host-side with configured Basic auth,
  strips token environment variables from Codex, and can reach whatever the Jira credential can.

### Asana adapter

- Config: use `tracker.kind: asana` with required `tracker.provider.project_gid`, optional
  `endpoint` (default `https://app.asana.com/api/1.0`), and `api_key` (defaults to `ASANA_PAT` and
  accepts `$VAR`); `active_states` and `terminal_states` are project section names.
- Scope: Symphony polls tasks in the configured project, treats their section as state, and omits
  deleted or out-of-project tasks during ID refreshes.
- Tool: `asana_api` sends relative Asana REST requests host-side with the configured auth; Symphony
  strips `ASANA_PAT` and configured token variables from the Codex child, while raw tool calls are
  not limited to the configured project.

### GitLab adapter

- Configure `tracker.kind: gitlab` with `tracker.provider.project_path`, optional `api_url`, and
  `api_key` (default `GITLAB_PAT`); use `opened` and `closed` tracker states.
- Symphony reads project issues by IID and exposes route-safe `GL-<iid>` identifiers.
- `gitlab_api` forwards raw GitLab REST requests with host-side auth and keeps configured tracker
  credentials and provider authentication aliases out of the Codex child.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

`mix github.plan plan.json --output validated-plan.json` validates a version-1 plan
offline and generates issue bodies with the acceptance contract. It checks required
scope coverage, schema, unique IDs, parent relationships, dependencies and lifecycle
deadlocks. It makes no GitHub writes and starts no scheduler. Publication still needs
native relationships and a board read-back matching the validated bundle. The ArtCom
host guide `docs/SYMPHONY_PLANNING.md` and `docs/symphony-plan.example.json` document the format.

The opt-in post-planning GitHub acceptance harness is in `scripts/e2e/run.py`.
It uses `scenario.json`, creates real issues and native relationships, and runs
the actual scheduler with either scripted app-server workers or real Codex.
Normal workflow status changes must come from workers; the controller only
releases Backlog, simulates human approvals, and quarantines its fixtures on failure.
Tasks make empty commits and merges while asserting unchanged tracked file trees.
The example workflow and real-Codex harness use workspace-write with on-request
approvals and Codex's automatic reviewer, allowing reviewed Git metadata writes.
Unresolved approval requests still stop the worker; the harness does not grant
full access or have Symphony approve these requests unconditionally.
The ArtCom host exposes `run-symphony-e2e.ps1`; its operational guide is
`docs/SYMPHONY_E2E.md`. Reports and workspaces are retained under `log/e2e/`.

Run the portable offline harness checks with
`python -m unittest discover -s scripts/e2e -p test_harness.py -v`.

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`
- `SYMPHONY_LIVE_SSH_WORKER_HOSTS` uses those SSH hosts when set, as a comma-separated list

`make e2e` runs two live scenarios:
- one with a local worker
- one with SSH workers

If `SYMPHONY_LIVE_SSH_WORKER_HOSTS` is unset, the SSH scenario uses `docker compose` to start two
disposable SSH workers on `localhost:<port>`. The live test generates a temporary SSH keypair,
mounts the host `~/.codex/auth.json` into each worker, verifies that Symphony can talk to them
over real SSH, then runs the same orchestration flow against those worker addresses. This keeps
the transport representative without depending on long-lived external machines.

Set `SYMPHONY_LIVE_SSH_WORKER_HOSTS` if you want `make e2e` to target real SSH hosts instead.

The live test creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear.

Run the opt-in read-only GitHub Project contract test (no issues are created or changed):

```bash
cd elixir
export SYMPHONY_LIVE_GITHUB_REPO=owner/scratch-repo
export SYMPHONY_LIVE_GITHUB_PROJECT_NUMBER=1
export SYMPHONY_LIVE_GITHUB_PROJECT_OWNER=owner
export GITHUB_TOKEN=...
SYMPHONY_RUN_GITHUB_LIVE_E2E=1 mix test test/symphony_elixir/github_live_e2e_test.exs
```

Run the opt-in Jira Cloud live test against a disposable project whose credential can browse,
create, comment on, transition, and delete issues:

```bash
cd elixir
export JIRA_BASE_URL=https://your-site.atlassian.net
export JIRA_EMAIL=...
export JIRA_API_TOKEN=...
export SYMPHONY_LIVE_JIRA_PROJECT_KEY=TEST
SYMPHONY_RUN_JIRA_LIVE_E2E=1 mix test test/symphony_elixir/jira_live_e2e_test.exs
```

Run the opt-in Asana live E2E against disposable Asana resources:

```bash
cd elixir
export ASANA_PAT=...
export SYMPHONY_LIVE_ASANA_WORKSPACE_GID=...
# Required only when the workspace is an organization:
# export SYMPHONY_LIVE_ASANA_TEAM_GID=...
SYMPHONY_RUN_ASANA_LIVE_E2E=1 mix test test/symphony_elixir/asana_live_e2e_test.exs
```

Run the opt-in GitLab live E2E against a disposable project:

```bash
cd elixir
export GITLAB_PAT=...
export SYMPHONY_LIVE_GITLAB_PROJECT_ID=...
SYMPHONY_RUN_GITLAB_LIVE_E2E=1 mix test test/symphony_elixir/gitlab_live_e2e_test.exs
```

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## Asset-bound human approval (GitHub)

ArtCom's model resolver forces `gpt-6-astra` / `high` for implementation of issues
with the `asset-generation` label or a valid `human_asset` acceptance contract.
This overrides Project/global implementation settings; catalog failures block
without substitution. Review/integration selections remain independent. The plan
compiler accepts `asset_generation: true`, requires a human_asset criterion and
emits the label. Existing worker sessions keep their original model; newly classified
implementation work rotates before its next turn so the replacement uses Astra.

The acceptance validator supports `human_asset` policies with `manifest`, `reviewers`
and `instructions`. An allowlisted GitHub User must post a separate
`## Asset Approval` comment with a fenced `symphony-asset-approval` JSON object:
version 1, decision `approved`, the complete `criterion`, manifest path and
`manifest_blob` (Git blob SHA). Workers supply `approval_comment_id` in that
criterion's evidence. Review and Done verify the comment and all manifest files
against remote source/target trees. See the consuming ArtCom repository's
`docs/ASSET_REVIEW.md` and `tools/asset_review.py` for packaging and human release.
No approval is inferred from a board move or an agent workpad. Missing human
approval pauses at Human Review without evidence; the human returns it to In review.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
