# Symphony

ArtCom asset-generation implementation workers always use Astra/high. The
`asset-generation` issue label or a valid `human_asset` contract overrides ordinary
model selection; unavailable Astra blocks the task without a fallback.

GitHub acceptance contracts can require human approval of exact art/audio review
packages. The `human_asset` gate verifies an allowlisted user's issue comment and
the manifest's Git blobs at review and integration. See [the implementation guide](elixir/README.md#asset-bound-human-approval-github).

This fork supports per-issue Codex model and reasoning selections from GitHub
Projects, with independent review/integration defaults and optional parent-feature
review overrides. ArtCom uses high effort for every model, Sol child reviewers
and Astra parent reviewers. See the Elixir README.
An optional `codex.project_id` assigns new worker tasks to a saved Codex project
without moving their per-issue workspaces or requiring an organizer agent.
The offline Elixir suite supports native Windows, including shell-command fixtures
and workspace link-safety tests without elevation; see the Elixir README for prerequisites.

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).

## ArtCom GitHub Projects workflow

This fork supports the ArtCom parent-feature/child-task lifecycle on GitHub Projects v2:
native blockers control dispatch, implementation/review/integration use fresh workers,
Human Review is a hard pause, and feature integration into main requires a manual approval
transition. See [the Elixir adapter contract](elixir/README.md#github-issues-adapter) and
[the example workflow](elixir/WORKFLOW.md). Persistent workspaces and compact workpads
survive worker limits. Quota failures pause new dispatch until the process restarts.
The example keeps the workspace sandbox and routes Git-write escalation requests
through Codex's automatic approval reviewer.

GitHub polling batches dependency/hierarchy reads and conditionally revalidates REST
responses to reduce shared API usage. GitHub quota exhaustion backs off until reset;
the restart-only pause above applies to Codex usage limits. API request accounting is
available in the observability state and acceptance-harness reports.

## No-op workflow acceptance harness

The GitHub workflow requires a versioned acceptance contract on every issue. Review
and integration must cover every criterion at the validated commit; changing the
contract invalidates approval. CI-backed criteria verify GitHub check runs, while
local/manual checks remain explicit reviewer evidence. `mix github.plan` validates
a structured task graph offline and generates Backlog issue bodies before publication.

Local GitHub workers can enable durable recovery with `agent.recovery_enabled`.
Task IDs, role/commit snapshots and compact checkpoints survive disposable workers.
Checkpoint enforcement and limits on consecutive failures, runs without repository
progress, and review rework pause only the affected issue in Human Review. ArtCom
enables these limits at three. `mix github.handoff` reads the saved handoff offline.

This fork includes an opt-in post-planning GitHub harness under `elixir/scripts/e2e`.
It verifies native task creation and the execution lifecycle using empty commits,
real GitHub and Git, with scripted or real Codex workers. It preserves tracked file
contents while exercising branch integration and the human approval boundary.
