# Repository Guidelines

## Project Structure & Module Organization
This repository stores workflow logic and platform contracts for the Telegram Knowledge Bot on `n8n 2.4.8`.
- `workflows/`: production workflow exports (`WFxx — Name.json`), e.g., `WF10` receiver, `WF20` normalize, `WF90` runner, `WF99` global error handler.
- `n8n examples/`: reference node and integration examples used during workflow authoring.
- `SQL.txt`: canonical PostgreSQL + `pgvector` schema.
- `SQL_tables.txt`: table-focused schema reference.
- `*.md`: architecture, contracts, and development rules.

## Build, Test, and Development Commands
There is no app build step; changes are made by editing workflow JSON and SQL/docs.
- `rg --files workflows "n8n examples"`: list workflow artifacts quickly.
- `jq . "workflows/WF99 — Global ERR Handler.json" >/dev/null`: validate JSON syntax before commit.
- `git diff -- workflows/ SQL.txt`: review only runtime-impacting changes.
- `rg "ERR —|Merge|Postgres" workflows/`: spot-check required node patterns.

## Coding Style & Naming Conventions
- Preserve exported n8n JSON formatting; use UTF-8 and avoid manual key reordering.
- Follow node prefixes from project rules: `IN —`, `DB —`, `ERR —`, `OUT —`, etc.
- Keep workflow names in `WFxx — Descriptive Name` format.
- Never use `$env.*`; secrets belong only in n8n Credentials.
- Keep SQL explicit and parameterized; avoid dynamic SQL concatenation.

## Testing Guidelines
- Minimum per workflow: happy path, edge case, failure path.
- Validate DB effects with `SELECT` checks against `SQL.txt` schemas.
- Ensure fail paths route through ErrorPipe (`ERR` nodes -> `WF99`).
- After editing branch logic, verify `Merge` nodes are present for multi-input joins.

## Commit & Pull Request Guidelines
Current history is mostly generic (`update`), so use clearer messages going forward.
- Preferred commit format: `wf20: enforce ErrorPipe on DB failure`.
- Keep each commit scoped to one workflow or one contract/schema change.
- PRs should include: changed files, behavior impact, test evidence (queries/logs), and linked issue/task.
- For workflow behavior changes, attach before/after screenshots from n8n editor when possible.

## Security & Configuration Tips
- Do not commit secrets, tokens, or credential exports.
- Treat `SQL.txt` and workflow error handling (`WF98`/`WF99`) as production-critical; review these changes with extra care.
