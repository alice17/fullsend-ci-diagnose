# fullsend-ci-diagnose

A [Fullsend](https://fullsend.sh/docs/guides/getting-started/) custom agent
that diagnoses failing **GitHub Actions** checks on a GitHub pull request,
classifies each failure as `flaky` / `infra` / `code` / `unknown`, posts a
sticky diagnosis comment, and optionally re-runs jobs it is confident are
flaky — within a per-check retry budget.

## How it works

1. **Pre-script** (`scripts/pre-ci-diagnose.sh`) runs on the trusted runner
   and collects failing checks, workflow log excerpts, and retry-budget
   counters for the PR's head commit into `check-context.json`.
2. **Agent** (`agents/ci-diagnose.md`) runs sandboxed with no GitHub token
   and no network access (only Vertex AI for inference). It reads the
   context file, diagnoses each failure using the `classify-ci-failure`
   skill, and writes a structured JSON result.
3. **Validation loop** (`scripts/validate-output-schema.sh`) checks the
   result against `schemas/ci-diagnose-result.schema.json` before the
   post-script runs.
4. **Post-script** (`scripts/post-ci-diagnose.sh`) runs on the trusted
   runner, posts the sticky PR comment, and re-runs only the checks
   individually classified `flaky` (confidence ≥ `MIN_RETRY_CONFIDENCE`,
   budget not exhausted).

All network reads happen in the pre-script; all network writes happen in
the post-script. The sandbox is a pure analysis environment.

## Layout

| Path | Purpose |
|------|---------|
| `agents/ci-diagnose.md` | Agent prompt (the full behavior spec) |
| `harness/ci-diagnose.yaml` | Harness config (model, providers, triggers, scripts, validation) |
| `policies/ci-diagnose.yaml` | Sandbox filesystem/network policy |
| `providers/vertex-ai.yaml` | Google Cloud Vertex AI inference provider |
| `env/gcp-vertex.env` | Vertex AI env mounted into the sandbox via `host_files` in the harness |
| `scripts/pre-ci-diagnose.sh` | Collects failing checks + logs before the agent runs |
| `scripts/post-ci-diagnose.sh` | Posts the PR comment and re-runs flaky checks |
| `scripts/validate-output-schema.sh` | Validates agent output against the schema |
| `schemas/ci-diagnose-result.schema.json` | JSON Schema for the agent's result |
| `skills/classify-ci-failure/SKILL.md` | Classification rules used by the agent |

## Usage

### Add to a project

In the target repo, register this agent by URL with the `fullsend` CLI —
this auto-pins the harness with a `#sha256=...` hash and adds it to
`.fullsend/config.yaml`:

```bash
fullsend agent add \
  https://github.com/alice17/fullsend-ci-diagnose/blob/main/harness/ci-diagnose.yaml \
  --fullsend-dir .fullsend
```

The target repo's `.fullsend/config.yaml` needs
`allowed_remote_resources` covering
`https://raw.githubusercontent.com/alice17/fullsend-ci-diagnose/`
(added automatically by `agent add`).

Alternatively, register it manually in `.fullsend/config.yaml`:

```yaml
agents:
  - name: ci-diagnose
    source: harness/ci-diagnose.yaml
```

Trigger it by commenting `/fs-ci-diagnose` on a non-fork pull request, or
run it manually:

```bash
fullsend run ci-diagnose
```

Manual runs require `GH_TOKEN`, `REPO_FULL_NAME`, and `GITHUB_ISSUE_URL` to
be set; `MAX_FLAKE_RETRIES` and `MIN_RETRY_CONFIDENCE` are injected by the
harness.

## Environment variables

Runner and sandbox variables (including retry tuning) are declared inline in
`harness/ci-diagnose.yaml` under `env.runner` and `env.sandbox` — there is no
separate `env/ci-diagnose.env` file. `MIN_RETRY_CONFIDENCE` is forwarded to
`env.sandbox` so the agent can reference it during classification. Edit values
in the harness:

```yaml
env:
  runner:
    MAX_FLAKE_RETRIES: "2"
    MIN_RETRY_CONFIDENCE: "0.7"
  sandbox:
    MIN_RETRY_CONFIDENCE: "0.7"
```

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_FLAKE_RETRIES` | `2` | Maximum number of times the post-script will re-run a check that the agent classified as `flaky`. Once a check has been retried this many times for the current head commit, it is skipped even if the agent still considers it flaky. Set to `0` to disable automatic re-runs entirely. |
| `MIN_RETRY_CONFIDENCE` | `0.7` | Minimum confidence score (0–1) the agent must assign to a `flaky` classification before the post-script will trigger a re-run. A higher value (e.g. `0.9`) makes re-runs more conservative; a lower value (e.g. `0.5`) re-runs more aggressively. |

`MAX_FLAKE_RETRIES` is only in `env.runner` because the sandbox agent never
re-runs checks — it only diagnoses and classifies failures. The re-run
logic lives entirely in the post-script, which runs on the runner.
`MIN_RETRY_CONFIDENCE` appears in both `env.runner` and `env.sandbox`: the
post-script uses it to gate re-runs, and the agent references it during
classification so it can reason about the threshold it is targeting.

To override these values, change them in `harness/ci-diagnose.yaml` and
commit. If you change `MIN_RETRY_CONFIDENCE`, keep the value in sync
between `env.runner` and `env.sandbox` so the agent and the post-script
agree on the threshold.

## Notes

Do **not** set `tools` or `disallowedTools` in the agent frontmatter.
Claude Code v2.1.119+ enforces those keys in `--agent` sessions, and scoped
`Bash(...)` patterns can strip the entire Bash tool. Steering belongs in
prompt constraints and sandbox policy; see
[ADR 0027](https://github.com/fullsend-ai/fullsend/blob/main/docs/ADRs/0027-allowed-and-disallowed-tools-for-agents.md).

## Requirements

- A GitHub token with `pull-requests:read`/`write`, `checks:read`, and
  `actions:read`/`write` scoped to the target repo (minted by dispatch)
- Google Cloud Vertex AI credentials for inference (`env/gcp-vertex.env`)
