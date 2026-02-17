#!/usr/bin/env bash
set -eu

# Guard: on pull_request, if critical files changed then PR must have needs-human label.
# Critical:
# - SQL.txt
# - Credentials.json
# - ACL workflows (WF00c/WF50/WF51 under workflows/)

NEEDS_LABEL="needs-human"

if [ "${GITHUB_EVENT_NAME:-}" != "pull_request" ]; then
  echo "[OK] Not pull_request event. Skipping guard."
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "[FAIL] jq is required for ci-guard-needs-human.sh"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "[FAIL] curl is required for ci-guard-needs-human.sh"
  exit 1
fi

EVENT_JSON="${GITHUB_EVENT_PATH:-}"
if [ -z "$EVENT_JSON" ] || [ ! -f "$EVENT_JSON" ]; then
  echo "[FAIL] GITHUB_EVENT_PATH is missing or invalid"
  exit 1
fi

PR_NUMBER="$(jq -r '.pull_request.number // empty' "$EVENT_JSON")"
BASE_SHA="$(jq -r '.pull_request.base.sha // empty' "$EVENT_JSON")"
HEAD_SHA="$(jq -r '.pull_request.head.sha // empty' "$EVENT_JSON")"
REPO_FULL="$(jq -r '.repository.full_name // empty' "$EVENT_JSON")"

if [ -z "$PR_NUMBER" ] || [ -z "$BASE_SHA" ] || [ -z "$HEAD_SHA" ] || [ -z "$REPO_FULL" ]; then
  echo "[FAIL] Missing PR metadata in event payload"
  exit 1
fi

echo "[INFO] PR #$PR_NUMBER repo=$REPO_FULL base=$BASE_SHA head=$HEAD_SHA"

git fetch --no-tags --prune --depth=200 origin "$BASE_SHA" "$HEAD_SHA" >/dev/null 2>&1 || true

CHANGED_FILES="$(git diff --name-only "$BASE_SHA" "$HEAD_SHA" || true)"
echo "[INFO] Changed files:"
printf '%s\n' "$CHANGED_FILES" | sed 's/^/  - /'

needs_guard=0

if printf '%s\n' "$CHANGED_FILES" | grep -qx "SQL.txt"; then
  echo "[WARN] SQL.txt changed"
  needs_guard=1
fi

if printf '%s\n' "$CHANGED_FILES" | grep -qx "Credentials.json"; then
  echo "[WARN] Credentials.json changed"
  needs_guard=1
fi

if printf '%s\n' "$CHANGED_FILES" | grep -Eiq '^workflows/WF00c\b|^workflows/WF50\b|^workflows/WF51\b'; then
  echo "[WARN] ACL-sensitive workflow changed (WF00c/WF50/WF51)"
  needs_guard=1
fi

if [ "$needs_guard" -eq 0 ]; then
  echo "[OK] No guarded changes."
  exit 0
fi

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "[FAIL] GITHUB_TOKEN is required to read PR labels"
  exit 1
fi

API_URL="https://api.github.com/repos/$REPO_FULL/issues/$PR_NUMBER/labels"
LABELS_JSON="$(curl -fsS \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "$API_URL")"

HAS_LABEL="$(printf '%s' "$LABELS_JSON" | jq -r --arg L "$NEEDS_LABEL" 'any(.[]; .name == $L)')"

if [ "$HAS_LABEL" != "true" ]; then
  echo "[FAIL] Guarded files changed but PR lacks label '$NEEDS_LABEL'."
  echo "       Add '$NEEDS_LABEL' label or revert critical changes."
  exit 1
fi

echo "[OK] Label '$NEEDS_LABEL' is present."
