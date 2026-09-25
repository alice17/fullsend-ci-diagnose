#!/usr/bin/env bash
# post-ci-diagnose.sh — Post diagnosis comment on a PR.
#
# Runs on the trusted runner after sandbox exit. The only effect is
# posting a sticky PR comment — re-runs of flaky checks are delegated to a
# user-owned ci-rerun workflow that reads the fullsend-ci-diagnose artifact
# (see ADR 0124, chaining-follow-up-workflows guide).
#
# Required env:
#   REPO_FULL_NAME       — owner/repo (set by dispatch)
#   GH_TOKEN             — GitHub token with pull-requests:write
#   GITHUB_ISSUE_URL     — issue or PR URL (set by dispatch or caller).
#                          `gh pr comment` and `gh pr view` accept the URL.
#                          A numeric id is extracted for REST and
#                          `fullsend issues post-comment --tracker github --number`.
#   MIN_RETRY_CONFIDENCE — minimum confidence to retry (set by harness yaml)
#   FULLSEND_OUTPUT_FILE — result filename (set by harness yaml)
set -euo pipefail

# Marker used by fullsend issues post-comment to upsert a sticky diagnosis comment.
COMMENT_MARKER='<!-- fullsend:ci-diagnose -->'
RESULT_NAME="${FULLSEND_OUTPUT_FILE}"

# Numeric id for REST paths and `fullsend issues post-comment --tracker github --number`.
pr_number_from_url() {
  local url="${GITHUB_ISSUE_URL}"
  if [[ "${url}" =~ /(issues|pull)/([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  echo "::error::GITHUB_ISSUE_URL has no issue/PR number: ${url}"
  exit 1
}

# Locate the agent's diagnosis JSON.
find_result_file() {
  local candidate
  for candidate in \
    ${FULLSEND_VALIDATED_ITERATION_DIR:+"${FULLSEND_VALIDATED_ITERATION_DIR}/output/${RESULT_NAME}"} \
    iteration-*/output/"${RESULT_NAME}"
  do
    [[ -f "${candidate}" ]] && { printf '%s' "${candidate}"; return 0; }
  done
  echo "::error::Result file ${RESULT_NAME} not found"
  exit 1
}

# True when the agent recommends a flake retry and confidence qualifies.
should_retry() {
  local result_file="$1"
  local min_confidence="${MIN_RETRY_CONFIDENCE}"

  jq -e \
    --argjson min_confidence "${min_confidence}" '
      .recommended_action == "retry"
      and .classification == "flaky"
      and (.confidence >= $min_confidence)
      and ((.retry_targets | length) > 0)
    ' "${result_file}" >/dev/null 2>&1
}

# Post a sticky diagnosis comment via fullsend issues post-comment.
post_sticky_comment() {
  local body_file="$1"
  export GITHUB_TOKEN="${GH_TOKEN}"
  fullsend issues post-comment \
    --tracker github \
    --project "${REPO_FULL_NAME}" \
    --number "$(pr_number_from_url)" \
    --marker "${COMMENT_MARKER}" \
    --token "${GH_TOKEN}" \
    --result "${body_file}"
}

main() {
  command -v gh >/dev/null || { echo "::error::gh not found"; exit 1; }
  command -v jq >/dev/null || { echo "::error::jq not found"; exit 1; }
  : "${REPO_FULL_NAME:?Required env REPO_FULL_NAME is not set}"
  : "${GH_TOKEN:?Required env GH_TOKEN is not set}"
  : "${GITHUB_ISSUE_URL:?Required env GITHUB_ISSUE_URL is not set}"
  : "${MIN_RETRY_CONFIDENCE:?Required env MIN_RETRY_CONFIDENCE is not set}"
  : "${FULLSEND_OUTPUT_FILE:?Required env FULLSEND_OUTPUT_FILE is not set}"
  export GH_TOKEN

  # 1) Load and validate agent output
  local result_file retry_note body_file
  result_file="$(find_result_file)"
  echo "::notice::Reading diagnosis result from ${result_file}"

  if ! jq empty "${result_file}" >/dev/null 2>&1; then
    echo "::error::Result is not valid JSON: ${result_file}"
    exit 1
  fi

  # 2) Determine retry recommendation for comment text.
  retry_note=""

  if should_retry "${result_file}"; then
    local target_count
    target_count="$(jq '.retry_targets | length' "${result_file}")"
    retry_note="**Retry:** recommended for ${target_count} flaky check(s). The \`ci-rerun\` workflow will handle re-runs from the run artifact."
  else
    local action classification
    action="$(jq -r '.recommended_action' "${result_file}")"
    classification="$(jq -r '.classification' "${result_file}")"
    if [[ "${action}" == "retry" ]]; then
      retry_note="**Retry:** skipped (classification=${classification}, min_confidence=${MIN_RETRY_CONFIDENCE})."
    fi
  fi

  # 3) Build and post sticky diagnosis comment
  local body
  body="$(jq -r '.pr_comment_markdown' "${result_file}")"
  if [[ -z "${body}" || "${body}" == "null" ]]; then
    echo "::error::Result missing pr_comment_markdown"
    exit 1
  fi

  body_file="$(mktemp)"
  {
    printf '%s\n' "${body}"
    [[ -n "${retry_note}" ]] && printf '\n---\n%s\n' "${retry_note}"
  } >"${body_file}"
  echo "::notice::Posting diagnosis comment on ${GITHUB_ISSUE_URL}"
  post_sticky_comment "${body_file}"
  rm -f "${body_file}"
  echo "::notice::ci-diagnose post-script complete"
}

main "$@"
