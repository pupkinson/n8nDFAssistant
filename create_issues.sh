#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-pupkinson/n8nDFAssistant}"

create_issue () {
  local title="$1"
  local labels="$2"
  local body_file="$3"

  echo "Creating: $title"
  gh issue create --repo "$REPO" --title "$title" --label "$labels" --body-file "$body_file" >/dev/null
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# ---------- Issue 0 ----------
cat >"$tmpdir/i0.md" <<'MD'
## Objective
Bootstrapping agent-driven workflow: AGENTS.md, GEMINI.md, docs/constraints.md + docs/escalation.md, issue/PR templates, CI guards, auto-labelers.

## Scope (in/out)
IN: create/update repo files for autonomous dev loop.  
OUT: do not modify business logic in workflows.

## Acceptance Criteria
- All required files exist (AGENTS.md, GEMINI.md, docs/*, .github/*, scripts/*).
- CI validates on PR and push; guard fails when critical changes lack `needs-human`.
- No secrets, no `$env.*`.

## Files likely touched
AGENTS.md, GEMINI.md, docs/*, .github/*, scripts/*

## Risk/Notes
Must not break existing CI.

## Test plan
- `node scripts/validate-workflows.mjs`
- PR touching SQL.txt without label → guard fails; with label → passes.
MD
create_issue "[BOOT] Repo Agent OS: templates + guards + docs" "tracked,type:feature" "$tmpdir/i0.md"

# ---------- Issue 1 ----------
cat >"$tmpdir/i1.md" <<'MD'
## Objective
Make ACL rules explicit and enforced: group-only retrieval, DM cross-chat rules, admin DM scope.

## Acceptance Criteria
- docs/constraints.md has explicit ACL rules.
- scripts/ci-guard-needs-human.sh fails if PR changes WF00c/WF50/WF51 without `needs-human`.

## Files likely touched
docs/constraints.md, scripts/ci-guard-needs-human.sh

## Risk/Notes
Avoid false positives on filenames.

## Test plan
- PR that edits WF50 without label → CI fail; add label → pass.
MD
create_issue "[ACL] Formalize ACL invariants in docs + add CI guard for WF00c/WF50/WF51" "tracked,needs-human,type:feature" "$tmpdir/i1.md"

# ---------- Issue 2 ----------
cat >"$tmpdir/i2.md" <<'MD'
## Objective
Ensure WF00c produces canonical ctx per contracts and routes errors via error output to WF99.

## Acceptance Criteria
- WF00c outputs ctx shape exactly per contracts doc.
- All Postgres/HTTP nodes use error output routing → WF99.
- Node Notes updated.

## Files likely touched
workflows/WF00c*.json (or existing equivalent), docs if contracts updated.

## Risk/Notes
ACL-sensitive → needs-human.

## Test plan
- validate-workflows passes
- manual import in n8n (no runtime test required)
MD
create_issue "[WF00c] Context Loader: contract alignment + error output wiring" "tracked,needs-human,acl-change,type:feature" "$tmpdir/i2.md"

# ---------- Issue 3 ----------
cat >"$tmpdir/i3.md" <<'MD'
## Objective
WF10 must normalize Telegram update into job envelope with correlation and enqueue into ops.jobs properly.

## Acceptance Criteria
- `_ctx.correlation_id` created/propagated.
- Insert/upsert ops.jobs is idempotent.
- No raw SQL. Postgres errors via error output.

## Files likely touched
workflows/WF10*.json

## Test plan
- validate-workflows passes
- optional: add fixture JSON under /tests/fixtures
MD
create_issue "[WF10] Telegram Webhook Receiver: strict Update→Job envelope and correlation propagation" "tracked,type:feature" "$tmpdir/i3.md"

# ---------- Issue 4 ----------
cat >"$tmpdir/i4.md" <<'MD'
## Objective
WF20 persists updates/messages with dedup keys; handles edits; maintains consistent linkage.

## Acceptance Criteria
- Uses only allowed Postgres operations.
- Errors → WF99 via error output.
- No big object-literals in expressions; prefer Set dotNotation.

## Files likely touched
workflows/WF20*.json

## Test plan
- validate-workflows passes
MD
create_issue "[WF20] Update Processor: Normalize & Persist (idempotent)" "tracked,type:feature" "$tmpdir/i4.md"

# ---------- Issue 5 ----------
cat >"$tmpdir/i5.md" <<'MD'
## Objective
WF90 safely executes ops.jobs with concurrency controls and retry policy; failures recorded.

## Acceptance Criteria
- Locking strategy implemented per architecture (job/advisory lock).
- job_run records persisted, status transitions correct.
- Postgres errors via error output to WF99.
- No infinite loops.

## Files likely touched
workflows/WF90*.json, SQL.txt only if mismatch (then needs-human).

## Test plan
- validate-workflows passes
- document manual test steps in PR
MD
create_issue "[WF90] Job Runner robustness: locking + retries + consecutive_failures" "tracked,type:feature" "$tmpdir/i5.md"

# ---------- Issue 6 ----------
cat >"$tmpdir/i6.md" <<'MD'
## Objective
Finalize ErrorEnvelope spec and guarantee all workflows route error outputs to WF99.

## Acceptance Criteria
- WF99 normalizes all errors into consistent envelope.
- WF98 catches platform errors and forwards to WF99.
- Each workflow includes wiring or documented exception.

## Files likely touched
workflows/WF98*.json, workflows/WF99*.json, docs

## Test plan
- validate-workflows passes
- simulated error path in n8n (manual)
MD
create_issue "[WF98/WF99] ErrorPipe: unify ErrorEnvelope and enforce routing" "tracked,type:feature" "$tmpdir/i6.md"

# ---------- Issue 7 ----------
cat >"$tmpdir/i7.md" <<'MD'
## Objective
WF30 fetches Telegram file binary, deduplicates, stores metadata, enqueues next jobs.

## Acceptance Criteria
- Works with configured storage mode per architecture.
- Dedup uses hash/file_unique_id policy.
- Errors via error output to WF99.

## Files likely touched
workflows/WF30*.json

## Test plan
- validate-workflows passes
- manual test using a Telegram file
MD
create_issue "[WF30] File Fetcher: Telegram file download → storage → DB (dedup)" "tracked,type:feature" "$tmpdir/i7.md"

# ---------- Issue 8 ----------
cat >"$tmpdir/i8.md" <<'MD'
## Objective
WF33 reliably extracts text from office docs and PDF/txt with correct provenance.

## Acceptance Criteria
- Uses installed converter nodes where required.
- Saves extracted text per SQL.txt.
- Errors via error output to WF99.

## Files likely touched
workflows/WF33*.json

## Test plan
- validate-workflows passes
- test fixtures: small docx/pptx/xlsx samples
MD
create_issue "[WF33] Document Text Extractor: DOCX/XLSX/PPTX support via converter node" "tracked,type:feature" "$tmpdir/i8.md"

# ---------- Issue 9 ----------
cat >"$tmpdir/i9.md" <<'MD'
## Objective
WF40 builds canonical content.documents record with correct ownership/visibility.

## Acceptance Criteria
- Correctly sets chat_id, dm_owner_user_id, visibility.
- Idempotent updates.
- Errors → WF99.

## Files likely touched
workflows/WF40*.json

## Test plan
- validate-workflows passes
MD
create_issue "[WF40] Document Builder: canonical document entity + linkage" "tracked,type:feature" "$tmpdir/i9.md"

# ---------- Issue 10 ----------
cat >"$tmpdir/i10.md" <<'MD'
## Objective
WF41 chunking and embeddings pipeline: validate vector dim 1536; upsert embeddings; enqueue retrieval indexes.

## Acceptance Criteria
- Embedding dimension check hard-fails to ErrorPipe if mismatch.
- No raw executeQuery unless DB RO read-only retrieval (no writes).
- All writes via allowed operations.

## Files likely touched
workflows/WF41*.json

## Test plan
- validate-workflows passes
- manual test: embed a small doc
MD
create_issue "[WF41] Chunk & Embed: strict 1536 validation + upsert vectors" "tracked,type:feature" "$tmpdir/i10.md"

# ---------- Issue 11 ----------
cat >"$tmpdir/i11.md" <<'MD'
## Objective
WF42 creates media description and metadata for retrieval while respecting chat policy flags.

## Acceptance Criteria
- Respects chat policy: indexing/response/media flags.
- Errors via error output to WF99.

## Files likely touched
workflows/WF42*.json

## Test plan
- validate-workflows passes
MD
create_issue "[WF42] Media Describe: policy-aware description pipeline" "tracked,type:feature" "$tmpdir/i11.md"

# ---------- Issue 12 ----------
cat >"$tmpdir/i12.md" <<'MD'
## Objective
WF50 orchestrates retrieval: build scope, retrieve candidates (hybrid) with ACL-first, prepare citations-ready context.

## Acceptance Criteria
- Group: only origin chat retrieval.
- DM: user across allowed chats; admin super-scope only in DM.
- If executeQuery used → only DB RO nodes + read-only SQL, no ';', no DML/DDL.
- Errors → WF99.

## Files likely touched
workflows/WF50  Query Orchestrator (ACL-first retrieval).json

## Risk/Notes
ACL-sensitive → needs-human.

## Test plan
- validate-workflows passes
- manual test: group vs DM queries
MD
create_issue "[WF50] Query Orchestrator: ACL-first retrieval end-to-end" "tracked,needs-human,acl-change,type:feature" "$tmpdir/i12.md"

# ---------- Issue 13 ----------
cat >"$tmpdir/i13.md" <<'MD'
## Objective
WF51 produces final answer with citations and enforces visibility and policy constraints.

## Acceptance Criteria
- Citations only reference allowed sources.
- No cross-chat leakage in group.
- Outputs structured response per contracts.
- Errors via error output to WF99.

## Files likely touched
workflows/WF51*.json

## Risk/Notes
ACL-sensitive → needs-human.

## Test plan
- validate-workflows passes
- manual test: group must refuse cross-chat
MD
create_issue "[WF51] Answerer: citations + visibility enforcement" "tracked,needs-human,acl-change,type:feature" "$tmpdir/i13.md"

# ---------- Issue 14 ----------
cat >"$tmpdir/i14.md" <<'MD'
## Objective
Improve validate-workflows.mjs enforcement:
- executeQuery only via DB RO policy with read-only SQL hygiene
- forbid $env. patterns
- optional: enforce node Notes presence for changed nodes

## Acceptance Criteria
- CI catches violations with clear messages.
- Does not break existing valid workflows.

## Files likely touched
scripts/validate-workflows.mjs

## Test plan
- run validate locally
- add a small “bad fixture” branch to confirm fail
MD
create_issue "[CI] Expand validate-workflows.mjs enforcement (DB RO + forbidden patterns)" "tracked,type:feature" "$tmpdir/i14.md"

# ---------- Issue 15 ----------
cat >"$tmpdir/i15.md" <<'MD'
## Objective
Refactor the four base docs into a consistent, non-contradictory set.

## Acceptance Criteria
- No conflicting statements between architecture/rules/contracts/handbook.
- All workflows referenced exist in repo.
- docs/PROJECT_MAP.md is accurate and links key workflows.

## Files likely touched
docs/*, existing architecture/rules/contracts/handbook md files.

## Test plan
- human review in PR
- ensure CI stays green
MD
create_issue "[Docs] Consolidate architecture + rules + contracts into a single coherent handbook" "tracked,type:feature" "$tmpdir/i15.md"

# ---------- Issue 16 ----------
cat >"$tmpdir/i16.md" <<'MD'
## Objective
Provide minimal fixtures to reproduce flows quickly.

## Acceptance Criteria
- tests/fixtures/telegram/update_message.json
- tests/fixtures/files/sample.(pdf|docx|pptx|xlsx) small
- docs/README_DEV.md explains how to use them

## Files likely touched
tests/fixtures/*, docs/README_DEV.md

## Test plan
- validate-workflows passes
- optional: manual run in n8n
MD
create_issue "[Ops] Add starter test fixtures (Telegram updates + docs)" "tracked,type:feature" "$tmpdir/i16.md"

# ---------- Issue 17 ----------
cat >"$tmpdir/i17.md" <<'MD'
## Objective
Document MVP: what bot does in groups vs DM; what is out-of-scope.

## Acceptance Criteria
- docs/MVP.md includes:
  - group flow
  - DM flow
  - admin flow
  - non-goals
  - privacy guarantees

## Files likely touched
docs/MVP.md

## Test plan
- none (doc-only)
MD
create_issue "[Product] Define MVP user flows and non-goals" "tracked,type:feature" "$tmpdir/i17.md"

echo "✅ Done. Created 18 issues in $REPO."
