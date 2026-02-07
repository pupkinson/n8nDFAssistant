# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Telegram Knowledge Bot — n8n-based RAG system that:
- Collects knowledge from Telegram chats (messages, files, links, media)
- Provides provable answers with citations via semantic search
- Enforces privacy/ACL per chat/user
- Uses PostgreSQL + pgvector for storage and embeddings

**Runtime:** n8n 2.4.8 (self-hosted), PostgreSQL + pgvector, Google Gemini API

## Repository Structure

```
workflows/           # n8n workflow JSON files (WFxx — Name.json)
SQL.txt             # PostgreSQL schema (source of truth for DB)
*.md                # Architecture docs, contracts, development rules
```

### Database Schemas
- `core.*` — tenants, bots, users, chat policies
- `raw.*` — raw Telegram updates (audit/replay)
- `tg.*` — normalized Telegram entities (users, chats, messages, files)
- `content.*` — documents, URLs, blob objects
- `kg.*` — chunks, embeddings (pgvector)
- `ops.*` — job queue, errors
- `audit.*` — QA sessions, citations

## Key Workflows

| Workflow | Purpose |
|----------|---------|
| WF10 | Telegram Webhook Receiver → RAW + job queue |
| WF20 | Update Processor → normalize tg.* entities |
| WF30-31 | File/Link fetchers |
| WF34-35 | Voice transcription (full STT / probe) |
| WF40 | Document Builder / Content Extractor |
| WF41 | Chunk & Embed → pgvector |
| WF90 | Job Runner (ops.jobs executor) |
| WF98 | Platform Error Catcher (n8n Error Workflow fallback) |
| WF99 | Global ERR Handler (ErrorPipe Contract v1) |

## Critical Development Rules

### Strict Prohibitions
1. **`$env.*` forbidden** — all secrets in n8n Credentials only
2. **No Code nodes** unless absolutely necessary (document WHY in Notes)
3. **No object literals in expressions** (`={{ { ... } }}`) — use Set + dotNotation
4. **No dynamic SQL concatenation**
5. **No `JSON.stringify()` for json/jsonb columns** — pass objects directly
6. **No Execute Query** unless approved with ADR
7. **No `deleteTable`** in Postgres nodes — only DELETE with explicit WHERE

### ErrorPipe Contract v1 (Mandatory)

All I/O errors (Postgres/HTTP/Telegram) must follow this pattern:

```
Postgres/HTTP Node (error output)
    ↓
ERR — Source <NodeName> (Set: includeOtherFields=true, _err.node/_err.operation/_err.table, attach _ctx)
    ↓
ERR — Prepare ErrorPipe v1 (Set: ctx=_ctx, error_context.*, ctx.contracts.errorpipe=1)
    ↓
Execute Workflow → WF99
    ↓
StopAndError
```

**Key invariants:**
- WF99 is the ONLY workflow that builds ErrorEnvelope
- `ops.errors` is written ALWAYS (best-effort)
- Job path (ops.jobs/ops.job_runs) only if `ctx.job_id` is set
- `correlation_id` is reused if provided, never regenerate existing

### Merge Node Policy (Hard Rule)

- Any node with 2+ incoming connections must be a **Merge** node
- For Merge with 3+ inputs: explicitly set `parameters.numberInputs = N`
- After IF/Switch exclusive branches: use Merge with Pass-through mode, connect both branches to Input 1

### Postgres Node Policy

- **Always Output Data:** OFF by default (ON only for optional lookups with explicit empty handling)
- **On Error:** Continue using error output → ErrorPipe v1
- For guaranteed 1 item: `Default item (Set) → Merge with select result`

### Data Preservation After I/O (Carry/Restore)

I/O nodes overwrite the item. Use one of:
- **CARRY pattern:** Store `carry.ctx`, `carry.req` before I/O → restore after
- **BRANCH+MERGE pattern:** Split flow, merge anchor item with I/O result under namespace (`db.*`)

## Envelope Contracts

### SuccessEnvelope
```json
{ "ok": true, "status_code": 200, "data": {}, "meta": { "source": "WFxx", "correlation": {...} } }
```

### ErrorEnvelope v1 (WF99 only)
```json
{ "ok": false, "status_code": 500, "data": null, "error": { "kind": "db|upstream|auth|rate_limit", "message": "...", "retryable": false, "details": {...} }, "meta": { "source": "WF99" } }
```

## Node Naming Convention

Prefixes: `IN —` trigger, `GUARD —` validation, `TG —` Telegram, `HTTP —` external, `DB —` Postgres, `RAW —` raw layer, `CAN —` canonical, `KG —` knowledge, `ACL —` access, `CTL —` routing, `ERR —` errors, `OUT —` envelope, `TST —` tests

## Testing Requirements

- Each workflow: minimum 3 tests (happy, edge, fail)
- Tests must write to DB and verify via SELECT
- Tests must cleanup (DELETE by test keys only)
- No mock branches that bypass prod path

## Workflow Artifact Naming

JSON exports: `WFxx__Name__n8n-2.4.8.json`

## Key Context Fields

```json
{
  "ctx": {
    "tenant_id": "uuid",
    "correlation_id": "uuid",
    "job_id": "number|null",
    "chat_id": "bigint|null",
    "visibility": "group|dm_private|admin_only",
    "contracts": { "errorpipe": 1 }
  }
}
```

## Job Types (ops.job_type enum)

`normalize_update`, `upsert_membership`, `fetch_tg_file`, `fetch_url`, `build_document`, `extract_text`, `chunk_document`, `embed_chunks`, `answer_query`, `reembed_model_migration`

## References

- `SQL.txt` — DB schema source of truth
- `telegram_knowledge_bot_архитектура_n_8_n_postgre_sql_pgvector.md` — full architecture
- `telegram_knowledge_bot_контракты_входа_выхода_workflow.md` — I/O contracts
- `telegram_knowledge_bot_жёсткие_правила_разработки_n_8_n_workflow_v_2.md` — development rules
- `canvas_updates_error_pipe_contract_v_1.md` — ErrorPipe contract details
