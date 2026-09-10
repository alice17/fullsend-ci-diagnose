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

See [`docs/agent.md`](docs/agent.md) for the full behavior spec, the
`check-context.json` shape, the result schema, dispatch environment, and
registration details.

## Layout

| Path | Purpose |
|------|---------|
| `agents/ci-diagnose.md` | Agent prompt |
| `docs/agent.md` | Full agent documentation |
| `harness/ci-diagnose.yaml` | Harness config (model, providers, triggers, scripts, validation) |
| `policies/ci-diagnose.yaml` | Sandbox filesystem/network policy |
| `providers/vertex-ai.yaml` | Google Cloud Vertex AI inference provider |
| `env/*.env` | Environment files mounted into the sandbox |
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

## Requirements

- A GitHub token with `pull-requests:read`/`write`, `checks:read`, and
  `actions:read`/`write` scoped to the target repo (minted by dispatch)
- Google Cloud Vertex AI credentials for inference (`env/gcp-vertex.env`)
