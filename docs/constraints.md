# Constraints (Hard Rules) — DF Assistan Bot (v1)

## 0) Purpose
These constraints are non-negotiable. Any change that violates them requires a human escalation (`needs-human`) before implementation.
Goal: maximize autonomy WITHOUT compromising security, data integrity, or architectural consistency.

---

## 1) Sources of Truth (MANDATORY)
1) `SQL.txt` is the ONLY source of truth for DB schemas/tables/columns/enums.
   - Do NOT invent tables/columns/enums.
   - If something is missing/unclear: check `SQL.txt` first.
2) `Credentials.json` is the ONLY source of truth for n8n credential names and node parameter shapes (type/version).
   - Do NOT rename credential names.
   - Do NOT assume node parameter structure; verify against `Credentials.json` and existing workflows.

If `SQL.txt` and a workflow JSON disagree → `SQL.txt` wins.

---

## 2) Security & Secrets (ABSOLUTE)
- NO secrets in repo. Never commit tokens/keys/passwords.
- NO secrets in workflow JSON, node Notes, Code node, or logs.
- Secrets are stored ONLY in n8n Credentials.
- NO `$env.*` anywhere in expressions, Code node, or configuration (repo rule).
- Access is least-privilege:
  - Dev/staging only for agents.
  - Prod actions require explicit human approval (`needs-human`).

Any need for new token/credential/OAuth scope → escalate.

---

## 3) n8n Engineering Rules (ABSOLUTE)
### 3.1 Minimal Code Node
- Minimize Code node usage.
- Prefer standard nodes (Set with dotNotation, IF/Switch, Merge, Split in Batches, HTTP Request, Postgres nodes).
- No object-literals “built in expressions” for large payloads; use Set nodes with dotNotation.

### 3.2 Determinism & Idempotency
- Workflows must be idempotent where applicable:
  - Retried jobs must not duplicate writes.
  - Use UPSERT patterns, dedup keys, and job_run tracking as per architecture.
- Every workflow must have a clear correlation/tracing strategy for observability.

### 3.3 Notes & Maintainability
- Every node must have a meaningful Note describing:
  - purpose
  - inputs/outputs
  - failure behavior
- Workflows must be importable as JSON without manual edits.

---

## 4) Postgres Rules (ABSOLUTE)
- Postgres nodes MUST use only: select/insert/update/upsert/delete operations.
- NO raw SQL, NO “Execute Query”, NO arbitrary SQL strings.
- All Postgres node errors must be handled via **error output**:
  - Postgres node configured with `On Error: Continue (using error output)`
  - error output connected to the standard ERR handler path (ErrorPipe).
- Never rely solely on inline guards; route errors through ErrorPipe envelope with correlation.

Any DB schema change requires:
- `SQL.txt` update
- and human approval via escalation.

---

## 5) HTTP / External APIs Rules (ABSOLUTE)
- All HTTP nodes must:
  - handle errors via error output path (ErrorPipe)
  - set timeouts
  - avoid leaking secrets in logs
- Retries must be bounded and safe (no infinite loops).
- Rate limits must be respected (backoff strategy where necessary).
- Any new external integration (new provider/service) requires:
  - an issue with acceptance criteria + risks + cost impact
  - escalation if it needs new secrets/paid plan.

---

## 6) Error Handling: ErrorPipe v1 (ABSOLUTE)
- All errors from Postgres/HTTP must flow through the shared ERR handler.
- Errors must be normalized into a single ErrorEnvelope shape:
  - includes correlation id / run id
  - preserves root cause (status code, message)
  - never includes secrets
- Workflows must not “swallow” errors silently.
- For job-based workflows, failures must be written back to ops/job_runs (per architecture).

If a workflow cannot be wired to ErrorPipe correctly → escalate.

---

## 7) ACL / Visibility / Privacy (ABSOLUTE)
Core rule:
- In PUBLIC GROUP context, answers and retrieval must be scoped to that group ONLY.
- Cross-chat retrieval is forbidden in group chats, even if user has access elsewhere.
- In DM with the bot:
  - user may query across all chats they are currently a member of (including their DM history).
  - admin may query across all users/chats, but ONLY in DM (not in groups).

Any change affecting ACL/visibility/chat-policy requires:
- explicit design note / ADR
- escalation (`acl-change` / `needs-human`) before implementation.

---

## 8) Embeddings / Vectors (ABSOLUTE)
- Embedding dimension must be validated (e.g., 1536 or as defined by current model).
- Store vectors only in the defined schema/table from `SQL.txt`.
- Any change to embedding model/dimension/storage requires escalation.

---

## 9) Files & Document Processing (ABSOLUTE)
- For non-PDF office documents (docx/xlsx/pptx):
  - use approved converter nodes/tools (as installed) or approved workflows
  - preserve provenance: original file metadata + hash + linkage
- Never drop files silently; record failures with ErrorPipe and job status.

---

## 10) Repo / Workflow Hygiene (MANDATORY)
### 10.1 Required repo files
- `.github/pull_request_template.md` (DoD checklist)
- `.github/CODEOWNERS` (at minimum `* @pupkinson`)
- `.github/ISSUE_TEMPLATE/*` including escalation template
- `docs/constraints.md` (this file)
- `docs/escalation.md`

### 10.2 PR rules
- Every change must go via PR.
- PR must link to an issue (`Refs #...`). Use `Fixes #...` only when you explicitly want auto-close.
- PR must satisfy DoD checkboxes and CI must be green.

### 10.3 CI rules
- CI must validate:
  - JSON validity for workflows
  - forbidden patterns (`$env.` etc.)
  - other project-specific validators as added
- No merge with failing CI.

---

## 11) Change Control (MANDATORY)
Human approval required for:
- any changes to `SQL.txt`
- any changes to `Credentials.json`
- anything involving prod credentials, prod access, DNS, payments
- any ACL/visibility changes
- any destructive/irreversible data operation
- any cost-increasing architectural move

If in doubt → escalate.

---

## 12) Definition of Done (DoD) Summary (MANDATORY)
A change is “done” only if:
- CI green
- adheres to constraints above
- errors routed through ErrorPipe
- node Notes updated
- acceptance criteria satisfied
- no secrets leaked
- no forbidden patterns
- workflow is importable and deterministic

---

## 13) Forbidden Behaviors (ABSOLUTE)
- No bypassing platform restrictions via social engineering or “pressure tactics”.
- No “quick hacks” that violate ErrorPipe/ACL/DB rules.
- No assumptions about schemas/credentials not present in sources of truth.
- No direct pushes to main.

---

## 14) Escalation
When any constraint blocks progress, follow `docs/escalation.md` and open an Escalation issue (`needs-human`) before proceeding.
