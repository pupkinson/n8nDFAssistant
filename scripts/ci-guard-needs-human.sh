#!/usr/bin/env bash
set -euo pipefail

# This script fails the CI if SQL.txt or Credentials.json changed in a PR
# but the PR does NOT have the label "needs-human".

NEEDS_LABEL="needs-human"

# Only enforce on pull_request events
if [[ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]]; then
  echo "[OK] Not a pull_request event (${GITHUB_EVENT_NAME:-}). Skipping guard."
  exit 0
fi

# PR metadata from GitHub event payload
EVENT_JSON="${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"
PR_NUMBER="$(jq -r '.pull_request.number' "$EVENT_JSON")"
BASE_SHA="$(jq -r '.pull_request.base.sha' "$EVENT_JSON")"
HEAD_SHA="$(jq -r '.pull_request.head.sha' "$EVENT_JSON")"
REPO_FULL="$(jq -r '.repository.full_name' "$EVENT_JSON")" # owner/repo

echo "[INFO] PR #$PR_NUMBER repo=$REPO_FULL base=$BASE_SHA head=$HEAD_SHA"

# Ensure we have history for diff
git fetch --no-tags --prune --depth=200 origin "$BASE_SHA" "$HEAD_SHA" >/dev/null 2>&1 || true

CHANGED_FILES="$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" || true)"
echo "[INFO] Changed files:"
echo "$CHANGED_FILES" | sed 's/^/  - /'

NEEDS_GUARD=0
if echo "$CHANGED_FILES" | grep -qx "SQL.txt"; then
  echo "[WARN] SQL.txt changed"
  NEEDS_GUARD=1
fi
if echo "$CHANGED_FILES" | grep -qx "Credentials.json"; then
  echo "[WARN] Credentials.json changed"
  NEEDS_GUARD=1
fi

if [[ "$NEEDS_GUARD" -eq 0 ]]; then
  echo "[OK] No guarded files changed. Guard passed."
  exit 0
fi

echo "[INFO] Guarded file(s) changed. Checking PR labels..."

# Fetch PR labels via GitHub REST API using GITHUB_TOKEN
API_URL="https://api.github.com/repos/$REPO_FULL/issues/$PR_NUMBER/labels"
LABELS_JSON="$(curl -sS -H "Authorization: Bearer ${GITHUB_TOKEN:?GITHUB_TOKEN is required}" \
  -H "Accept: application/vnd.github+json" "$API_URL")"

HAS_LABEL="$(echo "$LABELS_JSON" | jq -r --arg L "$NEEDS_LABEL" 'any(.[]; .name == $L)')"

if [[ "$HAS_LABEL" != "true" ]]; then
  echo "[FAIL] Guarded file(s) changed (SQL.txt and/or Credentials.json) but PR lacks label \"$NEEDS_LABEL\"."
  echo "       Add label \"$NEEDS_LABEL\" to the PR, or revert the guarded changes."
  exit 1
fi

echo "[OK] PR has label \"$NEEDS_LABEL\". Guard passed."
