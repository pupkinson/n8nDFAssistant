# Project Map

Source baseline: `telegram_knowledge_bot_архитектура_n_8_n_postgre_sql_pgvector.md` and current `workflows/*.json`.

## Core workflows
- `WF10 — Telegram Webhook Receiver (Update → Job)`
  - receives Telegram update, writes RAW/update context, enqueues processing

- `WF20 — Update Processor (Normalize & Persist)`
  - normalizes update into canonical entities, prepares downstream jobs

- `WF30 — File Fetcher`
  - downloads Telegram files and preserves content provenance

- `WF33 — Document Text Extractor`
  - extracts text from documents/media outputs into document content fields

- `WF40 — Document Builder`
  - assembles document-level records/metadata for downstream indexing

- `WF41 — Chunk & Embed`
  - chunks text and writes vector embeddings (pgvector path)

- `WF42 — Media Describe`
  - media understanding (image/video/audio descriptors) for searchable knowledge

- `WF50  Query Orchestrator (ACL-first retrieval)`
  - applies ACL scope and retrieval plan before answer generation

- `WF51 — Answerer (Answer with citations)`
  - builds final answer with citations and returns to Telegram

- `WF90 — Job Runner (ops.jobs executor)`
  - executes queued jobs and routes to worker workflows

- `WF98 — Platform Error Catcher`
  - workflow-level fallback for unmanaged n8n execution failures

- `WF99 — Global ERR Handler`
  - canonical ErrorPipe endpoint; normalizes/logs errors

## Guardrails tied to this map
- Any behavior change in `WF50`/`WF51` is ACL-sensitive and requires `needs-human`.
- Any ErrorPipe change must preserve route into `WF99`.
- Do not add workflow IDs in docs unless matching file exists in `workflows/`.
