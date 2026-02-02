# Telegram Knowledge Bot — Контракты входа/выхода workflow

Цель этого документа — зафиксировать **стабильные I/O контракты** между workflow, чтобы при генерации новых WF не копировать чужую логику, а опираться на заранее согласованные схемы.

Базовая среда:
- **n8n:** 2.4.8
- **DB:** PostgreSQL + pgvector (схема из `SQL.txt`)
- **Credentials:** строго из `Credentials.json`
- **n8n справочник:** MCP connection `n8n-mcp`

---

## 0) Общие типы и соглашения

### 0.1 Идентификаторы
- `tenant_id`: uuid
- `chat_id`: bigint (Telegram chat)
- `tg_user_id`: bigint (Telegram user)
- `message_id`: integer (Telegram message id внутри чата)
- `message_version_id`: bigint (FK на `tg.message_versions.id`)
- `document_id`: bigint (`content.documents.id`)
- `chunk_id`: bigint (`kg.chunks.id`)
- `job_id`: bigint (`ops.jobs.id`)
- `correlation_id`: uuid (сквозной идентификатор обработки)
- `trace_id`: string|null (внешний trace, если есть)

### 0.2 Visibility и приватность
Используется `core.visibility_scope`:
- `group`: данные из групп/каналов доступны участникам (с учётом allowlist в `core.tenant_users` и фактического membership в `tg.chat_memberships_current`).
- `dm`: данные из лички доступны только владельцу (`dm_owner_user_id`) и админам (роль в `core.tenant_users`).

### 0.3 Канонические envelopes
Все workflow **должны** возвращать один из двух форматов.

**SuccessEnvelope**
```json
{
  "ok": true,
  "status_code": 200,
  "data": { },
  "error": null,
  "meta": {
    "source": "WFxx",
    "ts": "<ISO>",
    "correlation": {
      "correlation_id": "<uuid>",
      "trace_id": "<string|null>",
      "tenant_id": "<uuid|null>",
      "chat_id": "<bigint|null>",
      "message_id": "<int|null>",
      "workflow": "<string|null>",
      "node": "<string|null>"
    }
  }
}
```

**ErrorEnvelope** (упрощённый v1 для проекта)
```json
{
  "ok": false,
  "status_code": 500,
  "data": null,
  "error": {
    "kind": "db|upstream|auth|rate_limit|unknown",
    "message": "<short>",
    "retryable": false,
    "details": { }
  },
  "meta": {
    "source": "WFxx",
    "ts": "<ISO>",
    "correlation": {
      "correlation_id": "<uuid>",
      "trace_id": "<string|null>",
      "tenant_id": "<uuid|null>",
      "chat_id": "<bigint|null>",
      "message_id": "<int|null>",
      "workflow": "<string|null>",
      "node": "<string|null>"
    }
  }
}
```

### 0.4 Общий `ctx`
`ctx` — это не «любая корзина», а **нормализованный контекст** для ACL/приватности/маршрутизации.

Минимальный контракт `ctx`:
```json
{
  "tenant_id": "<uuid>",
  "tg_user_id": "<bigint>",
  "chat_id": "<bigint|null>",
  "channel": "group|dm",
  "visibility": "group|dm",
  "dm_owner_user_id": "<bigint|null>",
  "role": "admin|user|blocked",
  "is_allowed": true,
  "trace_id": "<string|null>",
  "correlation_id": "<uuid>"
}
```

---

## 1) Список workflow проекта (канонический)

### WF00c — Context Loader (ACL + Chat Policy + Visibility)
**Назначение:** единое место нормализации `ctx` для всех WF.

**Trigger:** Execute Workflow Trigger (sub-workflow).

**Input (1 item):**
```json
{
  "req": {
    "tenant_id": "<uuid>",
    "tg_user_id": "<bigint>",
    "chat_id": "<bigint|null>",
    "channel": "group|dm",
    "trace_id": "<string|null>",
    "correlation_id": "<uuid|null>"
  }
}
```

**Output:** SuccessEnvelope с `data.ctx`.
```json
{ "ctx": { "tenant_id": "...", "role": "...", "is_allowed": true, "visibility": "group|dm", "chat_policy": {"allow_url_fetch":true, "allow_file_download":true, "allow_embedding":true, "retention_days_raw":90, "retention_days_documents":3650 } } }
```

**DB side-effects:**
- READ: `core.tenant_users` (required), `core.tenant_chats` (required для group), `core.chat_policies` (optional → defaults).
- READ: `tg.chat_memberships_current` (required для group доступа).

**Ошибки:**
- 403: пользователь не в allowlist / blocked.
- 404: чат не зарегистрирован/disabled для tenant.

---

### WF11 — Bot Transport Watchdog (Webhook health + mode state)
**Назначение:** мониторинг webhook/polling и запись состояния транспорта.

**Trigger:** Schedule.

**Input:**
```json
{ "req": { "tenant_id": "<uuid>", "bot_id": "<uuid>", "trace_id": null } }
```

**Output:** SuccessEnvelope (metrics/snapshot ids).

**DB side-effects:**
- READ: `core.bot_transport_config`, `core.bot_transport_state`, `core.bots`
- WRITE: `ops.webhook_health_snapshots`, `ops.bot_transport_events`, UPDATE `core.bot_transport_state`

---

### WF10 — Telegram Ingest (Webhook Receiver)
**Назначение:** принять Telegram update, записать RAW и поставить задачу на обработку в очередь.

**Trigger:** Webhook (Telegram → n8n).

**Input:** сырой Telegram Update (JSON).

**Output:** SuccessEnvelope с `data.job_id`.

**DB side-effects:**
- WRITE: RAW таблицы `raw.telegram_updates` и `raw.telegram_update_keys`
- WRITE: `ops.jobs` (job_type: обработка Telegram update; payload = raw update + мета)

**Примечания:**
- Никакой «тяжёлой логики» в WF10. Только валидация + RAW + enqueue.

---

### WF20 — Update Processor (Upsert tg.* + content discovery)
**Назначение:** разобрать update, записать факты в tg.* и создать задачи на контент (urls/files).

**Trigger:** Execute Workflow Trigger (запускается Job Runner’ом с job payload).

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "update": { /* raw telegram update */ }, "trace_id":"<string|null>" } }
```

**Output:** SuccessEnvelope:
```json
{
  "data": {
    "chat_id": 123,
    "message_id": 45,
    "message_fk": 999,
    "message_version_id": 1001,
    "created_jobs": { "url_jobs": [1,2], "file_jobs": [3] }
  }
}
```

**DB side-effects:**
- UPSERT/UPDATE: `tg.users`, `tg.chats`
- INSERT: `tg.messages` (identity), `tg.message_versions`, `tg.message_attachments`
- UPSERT/UPDATE: `tg.files`, `tg.file_instances` (если есть file_id)
- INSERT: `tg.chat_member_events` и UPDATE `tg.chat_memberships_current` (если update о member’ах)
- WRITE: `ops.jobs` для URL/file/download/extract, если найден контент

**Idempotency:**
- `tg.messages` уникален по `(tenant_id, chat_id, message_id)`
- `tg.message_versions` уникален по `(message_fk, version_no)`

---

### WF30 — URL Normalizer (Message → content.urls + fetch job)
**Назначение:** принять URL, нормализовать, upsert `content.urls`, создать `content.url_fetches` через job.

**Trigger:** Execute Workflow Trigger.

**Input:**
```json
{
  "req": {
    "tenant_id": "<uuid>",
    "url": "<string>",
    "ctx": { "chat_id": "<bigint|null>", "visibility": "group|dm", "dm_owner_user_id": "<bigint|null>", "message_version_id": "<bigint|null>" }
  }
}
```

**Output:** SuccessEnvelope:
```json
{ "data": { "url_id": 123, "normalized_url":"...", "fetch_job_id": 456 } }
```

**DB side-effects:**
- UPSERT: `content.urls`
- WRITE: `ops.jobs` (job_type: url_fetch)

---

### WF31 — URL Fetcher (Fetch → blob + documents)
**Назначение:** скачать URL, записать fetch, сохранить body в `content.blob_objects` (если нужно), создать/обновить `content.documents`.

**Trigger:** Execute Workflow Trigger (job).

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "url_id": 123, "ctx": {"visibility":"group|dm", "dm_owner_user_id":123, "chat_id":456, "message_version_id":789 } } }
```

**Output:** SuccessEnvelope:
```json
{ "data": { "url_fetch_id": 10, "document_id": 99, "status": "pending|done|error" } }
```

**DB side-effects:**
- INSERT: `content.url_fetches`
- UPSERT/INSERT: `content.blob_objects` (по sha256)
- INSERT: `content.documents` (doc_type=url)
- WRITE: `ops.jobs` для extract/chunk/embed (в зависимости от policy)

---

### WF32 — Telegram File Downloader (getFile + download → blob + documents)
**Назначение:** получить путь файла, скачать, сохранить blob, создать/обновить document.

**Trigger:** Execute Workflow Trigger (job).

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "file_id":"<string>", "file_unique_id":"<string>", "ctx": {"visibility":"group|dm", "dm_owner_user_id":123, "chat_id":456, "message_version_id":789 } } }
```

**Output:** SuccessEnvelope:
```json
{ "data": { "blob_object_id": 77, "document_id": 101, "file_unique_id":"..." } }
```

**DB side-effects:**
- UPDATE: `tg.file_instances` (tg_file_path, last_seen_at)
- UPSERT: `content.blob_objects`
- INSERT: `content.documents` (doc_type=file)
- WRITE: `ops.jobs` на extract/chunk/embed

---

### WF33 — Document Extractor (documents.pending → documents.text)
**Назначение:** извлечь текст (PDF/DOCX/HTML/изображения по необходимости), заполнить `content.documents.text`, выставить status.

**Trigger:** Execute Workflow Trigger (job).

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "document_id": 101 } }
```

**Output:** SuccessEnvelope:
```json
{ "data": { "document_id": 101, "status": "done|error", "token_count": 1234 } }
```

**DB side-effects:**
- UPDATE: `content.documents` (text, text_sha256, token_count, status, error)
- WRITE: `ops.jobs` на chunk/embed (если policy allow_embedding=true)

---

### WF40 — Chunker (documents.done → kg.chunks)
**Назначение:** нарезать document.text в чанки и записать `kg.chunks`.

**Trigger:** Execute Workflow Trigger (job).

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "document_id": 101, "chunking": {"max_chars": 1200, "overlap": 120} } }
```

**Output:** SuccessEnvelope:
```json
{ "data": { "document_id": 101, "chunks_created": 24 } }
```

**DB side-effects:**
- INSERT/UPSERT: `kg.chunks` (idempotent по (document_id, chunk_no))
- WRITE: `ops.jobs` на embed

---

### WF41 — Embedder (kg.chunks → kg.chunk_embeddings_1536)
**Назначение:** получить embeddings (Gemini), записать в pgvector таблицу.

**Trigger:** Execute Workflow Trigger (job).

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "document_id": 101, "model_id": 1 } }
```

**Output:** SuccessEnvelope:
```json
{ "data": { "document_id": 101, "model_id": 1, "embeddings_upserted": 24 } }
```

**DB side-effects:**
- READ: `kg.embedding_models`, `kg.chunks`
- UPSERT: `kg.chunk_embeddings_1536` (PK chunk_id+model_id)

---

### WF50 — QA Session Upserter (audit.qa_sessions)
**Назначение:** открыть/обновить сессию диалога вопрос-ответ.

**Trigger:** Execute Workflow Trigger (sub-workflow).

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "tg_user_id":123, "channel":"group|dm", "chat_id":456, "meta":{} } }
```

**Output:** SuccessEnvelope:
```json
{ "data": { "session_id": "<uuid>" } }
```

**DB side-effects:**
- UPSERT/UPDATE: `audit.qa_sessions` (last_at, meta)

---

### WF51 — Answerer (Mention/DM question → answer + citations)
**Назначение:** принять вопрос, проверить ACL через WF00c, найти релевантные chunks (pgvector), сформировать ответ, записать turn+citations, ответить в Telegram.

**Trigger:** Execute Workflow Trigger (job) ИЛИ напрямую из Update Processor для упоминания.

**Input:**
```json
{
  "req": {
    "tenant_id":"<uuid>",
    "tg_user_id":123,
    "channel":"group|dm",
    "chat_id":456,
    "question": "<text>",
    "question_message_version_id": 1001,
    "trace_id":"<string|null>"
  }
}
```

**Output:** SuccessEnvelope:
```json
{
  "data": {
    "session_id":"<uuid>",
    "turn_id": 555,
    "answer_text": "...",
    "citations": [ {"rank":1,"chunk_id":77,"score":0.82,"snippet":"...","source_ref":{}} ]
  }
}
```

**DB side-effects:**
- CALL: WF00c (required) → ctx.is_allowed
- WRITE: `audit.qa_turns`, `audit.qa_citations`
- READ: `kg.chunk_embeddings_1536` + join `kg.chunks` + join `content.documents` (с фильтрами visibility/tenant)

---

### WF60 — Retention & Pruning (policy-driven)
**Назначение:** удаление/архивация данных по retention политикам (raw vs documents).

**Trigger:** Schedule.

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "chat_id":456 } }
```

**Output:** SuccessEnvelope (counts).

**DB side-effects:**
- READ: `core.chat_policies`
- DELETE: по политике из `tg.*`, `content.*`, `kg.*`, `audit.*` (строго без Execute Query; допускается пакетная обработка через jobs).

---

### WF90 — Job Runner (ops.jobs executor)
**Назначение:** выбирать задачи из очереди и исполнять соответствующие worker workflow.

**Trigger:** Schedule (часто) + manual.

**Input:**
```json
{ "req": { "tenant_id":"<uuid>", "limit": 50, "worker_id":"<string>" } }
```

**Output:** SuccessEnvelope:
```json
{ "data": { "picked": 10, "succeeded": 9, "failed": 1 } }
```

**DB side-effects:**
- SELECT/UPDATE: `ops.jobs` (lock/pick)
- INSERT: `ops.job_runs`
- UPDATE: `ops.jobs` status/attempts/next_run_at
- CALL: WF20/WF31/WF32/WF33/WF40/WF41/WF51

---

### WF99 — Global ERR Handler
**Назначение:** единый обработчик ошибок: ErrorEnvelope + запись в `ops.errors` + (опционально) job failure фиксация.

**Trigger:** Execute Workflow Trigger (sub-workflow).

**Input:**
```json
{ "ctx": {"tenant_id":"<uuid>","workflow":"WFxx","node":"...","op":"...","job_id":123,"trace_id":null}, "errorMessage":"...", "statusCode": 429, "error": { } }
```

**Output:** всегда ErrorEnvelope.

**DB side-effects:**
- INSERT best-effort: `ops.errors`
- optional: UPDATE `ops.jobs` status='failed' + INSERT `ops.job_runs`

---

## 2) Правило эволюции контрактов
1) Любой новый workflow добавляется в этот документ отдельной секцией.
2) Любое изменение контрактов — через версионирование полей (добавление — ок, удаление/переименование — только с миграцией и указанием даты).
3) Все меж-WF вызовы должны передавать **минимальный payload** согласно контракту.

---

## 3) Минимальный набор данных для "ответа со ссылками"
Чтобы бот мог отвечать аргументированно и с источниками, цепочка должна обеспечивать:
- `tg.message_versions` хранит оригинальный payload и text/caption (и normalized_text)
- `content.documents` хранит извлечённый текст/мета + связи с message_version/url/file
- `kg.chunks` хранит чанки текста, привязанные к document_id
- `kg.chunk_embeddings_1536` хранит embeddings чанков
- `audit.qa_turns`/`audit.qa_citations` фиксируют Q/A и ссылки на chunk_id + snippet/source_ref

Это и есть минимально достаточный контур "knowledge bot".

