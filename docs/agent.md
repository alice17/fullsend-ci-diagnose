# ci-diagnose agent

Fullsend custom agent that diagnoses failing **GitHub Actions** CI checks on
GitHub pull requests.

When vendored into a repo as `.fullsend/`, this file belongs at
`docs/agent.md` (harness `doc:`). Layout and registration follow
[Bring Your Own Agent](https://fullsend.sh/docs/guides/user/bring-your-own-agent.html).
## Role

| Field | Value |
|-------|-------|
| Role | `review` (hosted mint identity; harness `role:`) |
| Registration name | `ci-diagnose` (`config.yaml` `agents[].name` / `fullsend run`) |
| Slug | `fullsend-ai-review` |
| Forge | GitHub |
| Inference | Google Cloud Vertex AI ([`providers/vertex-ai.yaml`](providers/vertex-ai.yaml)) |
| Harness | [`harness/ci-diagnose.yaml`](harness/ci-diagnose.yaml) |
| Prompt | [`agents/ci-diagnose.md`](agents/ci-diagnose.md) |
| Policy | [`policies/ci-diagnose.yaml`](policies/ci-diagnose.yaml) |
| Result schema | [`schemas/ci-diagnose-result.schema.json`](schemas/ci-diagnose-result.schema.json) |

## Behavior

1. **Pre-script** (`scripts/pre-ci-diagnose.sh`) collects PR failing-check
   context into `check-context.json` (failing check runs, commit statuses,
   workflow log excerpts, and retry-budget counters read from prior sticky
   comments). If no failing checks or statuses exist, the pre-script exits
   with code 1 **without** creating `check-context.json`, aborting the
   pipeline before the LLM agent starts
2. **Agent** analyses the pre-fetched context — workflow log excerpts and
   check metadata — diagnoses failures, classifies each as `flaky` /
   `infra` / `code` / `unknown` with per-failure confidence, and writes
   JSON. Classification logic is in the `classify-ci-failure` skill; the
   agent prompt delegates to it rather than duplicating the rules
3. **Validation loop** (`scripts/validate-output-schema.sh`) checks the
   result against the schema (`max_iterations: 2` in the harness)
4. **Post-script** (`scripts/post-ci-diagnose.sh`) posts a sticky PR comment
   via `fullsend post-comment` and may re-run **only the individually
   flaky** Actions jobs (`POST /repos/.../actions/jobs/{id}/rerun`) within
   a per-check retry budget (`MAX_FLAKE_RETRIES`; confidence ≥
   `MIN_RETRY_CONFIDENCE`; per-check `retries_remaining > 0`). Budgets are
   scoped to `head_sha` — new commits reset them. Defaults are set in
   `harness/ci-diagnose.yaml` (`2` and `0.7`). The same
   `MIN_RETRY_CONFIDENCE` is injected into the sandbox so the agent and
   post-script share one threshold.

The sandbox has **no GitHub token** and **no external API access** (only
Vertex AI for inference, via `providers: [vertex-ai]` and
[`env/gcp-vertex.env`](env/gcp-vertex.env)). All network reads happen in
the pre-script; all network writes happen in the post-script. The agent
prompt is runtime-agnostic (references "available tools" rather than a
specific inference provider).

The `model` is set in the harness (`ci-diagnose.yaml`), not in the agent
frontmatter, to avoid divergence.

Do **not** set `tools` or `disallowedTools` in the agent frontmatter. Claude
Code v2.1.119+ enforces those keys in `--agent` sessions, and scoped
`Bash(...)` patterns can strip the entire Bash tool (the agent then
hallucinates command output). Steering belongs in prompt constraints and
sandbox policy; see
[ADR 0027](https://github.com/fullsend-ai/fullsend/blob/main/docs/ADRs/0027-allowed-and-disallowed-tools-for-agents.md)
and [discussion #5182](https://github.com/fullsend-ai/fullsend/discussions/5182).

### `check-context.json` shape

Written by the pre-script to `CHECK_CONTEXT_FILE`
(set by `harness/ci-diagnose.yaml`). The runner-side path is
`target-repo/check-context.json` (relative to the pre-script's cwd, which
is `$GITHUB_WORKSPACE`, **not** the target-repo checkout). This places the
file inside the target-repo checkout so it is carried into the sandbox by
the "project code copy" tar step (`/sandbox/workspace/target-repo/check-context.json`).
Using `host_files` is not viable for URL-sourced harnesses because
`env.runner` vars are not in the CLI's process environment at copy time,
and absolute `src` paths are rejected:

- `repo_full_name`, `pr_number`, `head_sha`, `pr_url`, `pr_title`,
  `head_ref`, `base_ref`, `collected_at`. `head_sha` is always taken from
  `gh pr view --json headRefOid`; the script does not read `HEAD_SHA` from
  the environment
- `failing_checks[]` — check runs with conclusions `failure`,
  `timed_out`, `cancelled`, `action_required`, or `startup_failure`.
  Skipped conclusions and checks named `dispatch / …` are dropped before
  the agent sees them. Each entry has `check_name`, `check_run_id`,
  `conclusion`, `status`, `details_url`, `html_url`, `started_at`,
  `completed_at`, and `app_slug`. Check-run output blobs
  (`output_title` / `output_summary` / `output_text`) are **not** included
- `failing_statuses[]` — commit statuses in `failure` / `error` state
- `workflow_logs` — object keyed by workflow run ID (string) with truncated
  failed-job log excerpts as values (max `LOG_EXCERPT_MAX` chars, default 8000)
- `retry_budget` — `{ max_flake_retries, per_check: { <name>: { retries_used, retries_remaining } } }`.
  Retry counts are per-check and scoped to `head_sha`, so new commits
  implicitly reset the budget. Markers are read from sticky PR
  conversation comments via `gh pr view` (format:
  `<!-- fullsend:ci-diagnose-retries:CHECK_NAME:SHA:N -->`), not the
  Issues comments REST API, so a fine-grained PAT with
  `pull-requests:read` is enough

### Result schema

The result JSON (`ci-diagnose-result.schema.json`) includes both top-level
and per-failure classification:

- **Top-level** `classification` / `confidence` — the rollup used by the
  post-script to gate retries
- **Per-failure** `classification` / `confidence` — individual diagnosis per
  check run, surfaced in the PR comment table

The `retry_targets` array must contain **only** failures individually
classified as `flaky`. Non-flaky failures are never retried, even when the
overall classification is `flaky`.

### PR comment format

The `pr_comment_markdown` field uses a structured layout:

1. **Failures table** — one row per failed job with check name (linked to
   the run), root cause, classification, and confidence
2. **Action** — whether a retry was performed and why/why not
3. **Details** — additional context for the PR author

The post-script appends a short **Retry:** line and, when jobs were
re-run, HTML retry markers used by the next pre-script pass.

## Triggers

Dispatch runs this agent when a human comments `/fs-ci-diagnose` on a
non-fork pull request. The CEL expression is on the harness `trigger`
field ([CEL Triggers Reference](https://fullsend.sh/docs/guides/user/cel-triggers-reference.html)).

`fullsend run ci-diagnose` works for local/manual runs. Pass `GH_TOKEN`,
`REPO_FULL_NAME`, and `GITHUB_ISSUE_URL`. The harness injects
`MAX_FLAKE_RETRIES` and `MIN_RETRY_CONFIDENCE`; the scripts require those
variables to be set. The slash command is still `/fs-ci-diagnose`.

Not wired yet: auto-run on GitHub Actions check failure. The installed
shim does not subscribe to `check_run` / `check_suite` events.

## Dispatch environment

Custom harness agents run through `reusable-dispatch.yml` `harness-run`,
which injects `GITHUB_ISSUE_URL`, `REPO_FULL_NAME`, and a minted `GH_TOKEN`.
The pre-script passes `GITHUB_ISSUE_URL` to `gh pr view`. The post-script
posts with `fullsend post-comment` and re-runs jobs with `gh api`. A numeric
id is parsed from the URL only for REST paths and
`fullsend post-comment --number`. `HEAD_SHA` is set from
`gh pr view --json headRefOid`. `MAX_FLAKE_RETRIES` and
`MIN_RETRY_CONFIDENCE` defaults (`2` and `0.7`) are set in
`harness/ci-diagnose.yaml` `env.runner` and passed through to the scripts.

## Status comments and mint role

Hosted mint only allows canonical roles (`review`, `coder`, `triage`, …).
This harness therefore sets `role: review` and `slug: fullsend-ai-review`
so token minting uses the shared review GitHub App. A custom role such as
`ci-diagnose` needs a
[standalone mint](https://fullsend.sh/docs/guides/user/custom-agent-identity.html).

Register the agent in the consuming repo's `.fullsend/config.yaml`
`agents:` list, for example:

```yaml
agents:
  - name: ci-diagnose
    source: harness/ci-diagnose.yaml
```

Custom agents do not belong in `roles:` — that list only enables built-in
stages ([Bring Your Own Agent](https://fullsend.sh/docs/guides/user/bring-your-own-agent.html#config-file-fullsendconfigyaml)).

After `fullsend run`, the composite action reconciles status comments with
`fullsend reconcile-status --role <name>`. If that name is the config
registration (`ci-diagnose`) rather than the harness `role:` (`review`),
hosted mint returns HTTP 403 `role not allowed`.

