# Constraints (Hard Rules)

## 1) Sources of truth
- `SQL.txt` is the only source of truth for schema, enums, table/column names, and DB behavior.
- `Credentials.json` is the only source of truth for credential names and node credential wiring.
- If workflow JSON conflicts with `SQL.txt` or `Credentials.json`, fix workflow JSON.

## 2) Security and configuration
- No secrets in git, workflow JSON, notes, scripts, logs, or docs.
- Secrets live only in n8n Credentials.
- `$env.*` is forbidden in workflows, scripts, and examples.
- Do not invent schema, credentials, or hidden config.

## 3) n8n implementation rules
- Nocode-first: use native nodes first.
- Keep Code node usage minimal and justified.
- Prefer `Set` with dotNotation for object assembly.
- Keep workflows deterministic and importable without manual fixups.
- Update node Notes on all changed nodes.

## 4) Postgres and ErrorPipe rules
- Every Postgres node must use `On Error: Continue (using error output)`.
- Error output must route to ERR path and then to `WF99 — Global ERR Handler`.
- Do not swallow DB errors or bypass WF99.

### executeQuery policy
- Default: forbidden.
- Controlled exception allowed only for read-only retrieval and only when all checks pass:
  - node name starts with `DB RO - ` or `DB RO — `
  - SQL starts with `SELECT` or `WITH`
  - SQL contains no semicolons
  - SQL contains no DML/DDL keywords (`INSERT`, `UPDATE`, `DELETE`, `MERGE`, `ALTER`, `DROP`, `CREATE`, `TRUNCATE`, `GRANT`, `REVOKE`, `VACUUM`, `ANALYZE`)
  - no side effects

## 5) ACL and visibility
- Group chat: retrieval scope is current `chat_id` only.
- Group chat: cross-chat and DM data retrieval is forbidden.
- DM: user scope is own DM plus chats where user is current member and chat policy allows access.
- Admin super-scope is allowed only in DM, never in group context.
- Any ACL model change requires `needs-human` escalation.

## 6) CI and PR gates
- PR must be linked to an issue.
- CI must be green (`node scripts/validate-workflows.mjs`).
- PR template checklist must be completed.
- `needs-human` label is mandatory for critical changes (`SQL.txt`, `Credentials.json`, ACL workflows).

## 7) Forbidden shortcuts
- No direct push to `main`.
- No bypass of policy, permissions, or platform controls.
- No destructive changes without explicit human approval.
