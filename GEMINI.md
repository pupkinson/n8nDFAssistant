# GEMINI CLI Context

## Project overview
DF Assistant Bot is a Telegram knowledge bot built on n8n + PostgreSQL + pgvector. Workflows in `workflows/` implement ingest, normalization, retrieval, and answer generation with strict ACL and ErrorPipe rules.

## Files that matter most
- `SQL.txt` (schema source of truth)
- `Credentials.json` (credential/node source of truth)
- `workflows/*.json` (runtime behavior)
- `scripts/validate-workflows.mjs` (policy gate)
- `docs/constraints.md` and `docs/escalation.md` (hard rules)
- `telegram_knowledge_bot_архитектура_n_8_n_postgre_sql_pgvector.md`
- `telegram_knowledge_bot_жёсткие_правила_разработки_n_8_n_workflow_v_2.md`
- `telegram_knowledge_bot_контракты_входа_выхода_workflow.md`

## Rule summary
- Do not invent schema/credentials.
- No secrets in repo.
- No `$env.*` usage.
- Postgres errors must go through WF99.
- `executeQuery` only under `DB RO` read-only constraints.
- Respect ACL: group scope is current chat only; admin super-scope only in DM.

## How Gemini should respond
- Keep output short and actionable.
- Cite repository file paths for each claim.
- Propose concrete next actions and command/diff suggestions.
- Never include or suggest committing secret values.
- If blocked by policy or ambiguity, recommend escalation with minimal safe option.
