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
   runner and posts the sticky PR comment. Re-runs of flaky checks are
   handled entirely by the adopting repo's `ci-rerun` workflow, which
   reads the artifact independently.

All network reads happen in the pre-script; all network writes happen in
the post-script. The sandbox is a pure analysis environment.

## Layout

| Path | Purpose |
|------|---------|
| `agents/ci-diagnose.md` | Agent prompt (the full behavior spec) |
| `harness/ci-diagnose.yaml` | Harness config (model, providers, triggers, scripts, validation) |
| `policies/ci-diagnose.yaml` | Sandbox filesystem/network policy |
| `env/gcp-vertex.env` | Vertex AI env mounted into the sandbox via `host_files` in the harness |
| `scripts/pre-ci-diagnose.sh` | Collects failing checks + logs before the agent runs |
| `scripts/post-ci-diagnose.sh` | Posts the PR comment |
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
be set.

## Environment variables

Runner and sandbox variables are declared inline in
`harness/ci-diagnose.yaml` under `env.runner` and `env.sandbox` — there is no
separate `env/ci-diagnose.env` file. Edit values in the harness:

```yaml
env:
  runner:
    MAX_FLAKE_RETRIES: "2"
```

Retry tuning (`MIN_RETRY_CONFIDENCE`, `max-flake-retries`) is configured in the
adopting repo's `ci-rerun` workflow, not in the harness.

| Variable | Default | Scope | Description |
|----------|---------|-------|-------------|
| `MAX_FLAKE_RETRIES` | `2` | runner | Maximum number of times `ci-rerun` will re-run a check classified as `flaky`. Once exhausted the check is skipped. Set to `0` to disable automatic re-runs. |
| `MIN_RETRY_CONFIDENCE` | `0.7` | – | Minimum per-check confidence (0–1) for a `flaky` classification to qualify for retry. Used by the adopting repo's `ci-rerun` workflow (passed as the `min-retry-confidence` input) to filter the agent's `failures[]`. Higher = more conservative. Not consumed by the post-script. |

The sandbox agent only diagnoses and classifies — retry decisions are made
deterministically by the adopting repo's `ci-rerun` workflow.

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
