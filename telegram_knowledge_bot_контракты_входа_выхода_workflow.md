# Telegram Knowledge Bot — Контракты входа/выхода workflow

Цель этого документа — зафиксировать **стабильные I/O контракты** между workflow, чтобы при генерации новых WF не копировать чужую логику, а опираться на заранее согласованные схемы.

Базовая среда:

- **n8n:** 2.4.8
- **DB:** PostgreSQL + pgvector (схема из `SQL.txt`)
- **Credentials:** строго из `Credentials.json`
- **n8n справочник:** 2×MCP (см. canvas «Telegram Knowledge Bot — единый регламент проекта (n8n 2.4.8) + 2×MCP»)
  - MCP#1: `n8n-mcp`
  - MCP#2: второй MCP сервера проекта (имя/правила — в «едином регламенте»)

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

Используется `core.visibility_scope` (см. `SQL.txt`):

- `group`: данные из групп/каналов доступны участникам (с учётом allowlist в `core.tenant_users` и фактического membership в `tg.chat_memberships_current`).
- `dm_private`: данные из лички доступны только владельцу (`dm_owner_user_id`) и админам (роль в `core.tenant_users`).
- `admin_only`: данные доступны только админам (используем точечно для сервисных логов/внутренних заметок).

### 0.2.1 Триггеры ответа (DM vs Group)

**DM (личная переписка):**

- Если пользователь `enabled=true` в `core.tenant_users` — бот считает осмысленное сообщение обращением к нему и отвечает.
- В DM пользователь может запрашивать информацию из других чатов **только в пределах прав**:
  - DM владельца (dm\_owner\_user\_id=user)
  -
    - чаты, где пользователь является **текущим** участником (`tg.chat_memberships_current`) и чат разрешён политикой.

**Group (публичный чат):**

- Бот отвечает только при явном обращении:
  1. mention `@<bot_username>` в `entities/caption_entities`, ИЛИ
  2. reply на сообщение бота (`reply_to_message` от бота), ИЛИ
  3. `/command@<bot_username>` (если включена поддержка команд).
- В group-ответах источники строго ограничены **текущим ****chat\_id**. Запросы «принеси из другого чата/лички» в группе — отказ.

### 0.2.2 Голосовые сообщения (STT): авто и по запросу

Настройки на уровне chat policy (в `core.chat_policies` или эквивалент по SQL.txt):

- `auto_transcribe_voice` (bool)
- `assistant_name` / `wake_name` (string)

Поведение:

- `auto_transcribe_voice=true`: любое voice → job `voice_transcribe` → транскрипт в БД → reply транскриптом.
- `auto_transcribe_voice=false`: только по запросу:
  - текстом: reply на voice + mention + «расшифруй»;
  - голосом: voice с `wake_name` + просьба;
  - для экономии: допускается `voice_probe` (2–5 сек) → если wake найден → `voice_transcribe`.

### 0.2.3 Авто-анализ мультимедиа и ссылок (обязательный контур знаний)

Требование: **любой** мультимедиа-объект (аудио/voice, видео, изображение, документ, ссылка) должен быть не только сохранён, но и **проанализирован** так, чтобы его можно было находить по смыслу.

Политика (на уровне чата/tenant, хранить в `core.chat_policies.meta` или эквиваленте):

- `auto_analyze_media` (bool): анализировать вложения автоматически.
- `auto_transcribe_voice` (bool): auto-STT для voice.
- `allow_file_download` / `allow_url_fetch` / `allow_embedding` (bool): разрешения на скачивание/парсинг/эмбеддинг.

Единый принцип хранения результатов:

- **основной поисковый текст** → `content.documents.text`
- **структурированные результаты** → `content.documents.meta` (JSON):
  - для audio/voice: `transcript`, `language`, `segments?`
  - для video: `description`, `scenes?`, `objects?`, `timestamps?`
  - для image: `caption`, `ocr_text?`, `objects?`
  - для docs: `extracted_text`, `ocr_text?`, `tables?`
  - для url: `page_text`, `title`, `summary?`

Дальше весь этот текст проходит общий конвейер: `chunk_document` → `embed_chunks`, чтобы искать **по смыслу**.

### 0.3 Канонические envelopes

Канонический формат обмена между workflow:

1. На **success** любой workflow возвращает **SuccessEnvelope**.
2. На **I/O ошибке** (Postgres/HTTP/Telegram) рабочие workflow **не строят ErrorEnvelope сами**. Они обязаны:
   - на error-ветке **явно** проставить источник ошибки (`_err.*`) и **приклеить** контекст,
   - вызвать **WF99** (Execute Workflow),
   - завершить ветку через **StopAndError**.
3. **ErrorEnvelope формируется и возвращается только WF99** (ErrorPipe Contract v1). fileciteturn20file0

**SuccessEnvelope**

```json
{
  "ok": true,
  "status_code": 200,
  "data": {},
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

**ErrorEnvelope v1 (только WF99)**

```json
{
  "ok": false,
  "status_code": 500,
  "data": null,
  "error": {
    "kind": "db|upstream|auth|rate_limit|unknown",
    "message": "<short>",
    "retryable": false,
    "details": {
      "ctx": {},
      "error_context": {},
      "raw_error": {}
    }
  },
  "meta": {
    "source": "WF99",
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
  },
  "_internal": {
    "persist_failed": false,
    "ops_error_id": "<bigint|null>"
  }
}
```

**Инвариант:** `error.details.*` — **объекты**, а не строки (никаких stringify / raw jsonOutput). fileciteturn20file0

### 0.4 Общий `ctx`

`ctx` — нормализованный контекст для ACL/приватности/маршрутизации.

Каноническое имя в меж-WF контрактах — `ctx`. `_ctx` допустим только как внутренний контейнер внутри одного WF.

Минимальный контракт `ctx`:

```json
{
  "tenant_id": "<uuid>",
  "tg_user_id": "<bigint>",
  "chat_id": "<bigint|null>",
  "channel": "group|dm",
  "visibility": "group|dm_private|admin_only",
  "dm_owner_user_id": "<bigint|null>",
  "role": "admin|user|readonly|blocked",
  "is_allowed": true,
  "trace_id": "<string|null>",
  "correlation_id": "<uuid>",
  "job_id": "<number|null>",
  "contracts": {
    "errorpipe": 1
  }
}
```json
{
  "tenant_id": "<uuid>",
  "tg_user_id": "<bigint>",
  "chat_id": "<bigint|null>",
  "channel": "group|dm",
  "visibility": "group|dm_private",
  "dm_owner_user_id": "<bigint|null>",
  "role": "admin|user|blocked",
  "is_allowed": true,
  "trace_id": "<string|null>",
  "correlation_id": "<uuid>",
  "job_id": "<number|null>",
  "contracts": {
    "errorpipe": 1
  }
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
{ "ctx": { "tenant_id": "...", "role": "...", "is_allowed": true, "visibility": "group|dm_private", "chat_policy": {"allow_url_fetch":true, "allow_file_download":true, "allow_embedding":true, "retention_days_raw":90, "retention_days_documents":3650 } } }
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
- WRITE: `ops.jobs` (job\_type: обработка Telegram update; payload = raw update + мета)

**ErrorPipe v1 (обязательно):** WF10 является источником правды для `error_context` при DB-ошибках своих Postgres-нод:

- Postgres error output → Set `ERR — Source <NodeName>` (includeOtherFields=true) с `_err.node/_err.operation/_err.table` + приклейка `ctx` → Set `ERR — Prepare ErrorPipe v1` (создаёт `error_context.*`, копирует `ctx`) → Execute WF99 → StopAndError. fileciteturn20file0

**Примечания:**

- Никакой «тяжёлой логики» в WF10. Только валидация + RAW + enqueue.

---

### WF20 — Update Processor (Upsert tg.* + discovery + job fan-out)

**Назначение:** разобрать update, записать факты в `tg.*`, определить необходимость ответа (DM/Group rules) и создать задачи `ops.jobs` на дальнейшую обработку контента и/или ответ.

**Trigger:** Execute Workflow Trigger (запускается Job Runner’ом/worker).

**Input:**

```json
{ "req": { "tenant_id":"<uuid>", "update": { /* raw telegram update */ }, "trace_id":"<string|null>" } }
```

**Output:** SuccessEnvelope (как и ранее), но `created_jobs` отражает типы из `ops.job_type`.

**DB side-effects:**

- UPSERT/UPDATE: `tg.users`, `tg.chats`
- INSERT/UPSERT: `tg.messages` (identity), `tg.message_versions`, `tg.message_attachments`
- UPSERT/UPDATE: `tg.files`, `tg.file_instances` (если есть file_id)
- INSERT/UPDATE: `tg.chat_member_events` и `tg.chat_memberships_current` (если update о member’ах)

- WRITE: `ops.jobs` (payload — **объект**, без stringify) — **строго enum из `ops.job_type` (см. `SQL.txt`)**:
  - `fetch_tg_file` — для каждого file/voice/video/photo/document
  - `fetch_url` — для каждого URL
  - `build_document` — создать/обновить `content.documents` (doc_type=`file|url|message`, visibility и связи)
  - `extract_text` — **универсальный анализ**:
    - voice/audio → transcript
    - video → описание/сцены
    - image → caption + OCR (если нужно)
    - docs → извлечённый текст (+ OCR для сканов)
    - url → page text (+ title/summary)
  - `chunk_document` → `embed_chunks` (если policy `allow_embedding=true`)
  - `answer_query` — если `interaction.should_respond=true`

**Idempotency:**

- `tg.messages` уникален по `(tenant_id, chat_id, message_id)`
- `tg.message_versions` уникален по `(message_fk, version_no)`

**Idempotency:**

- `tg.messages` уникален по `(tenant_id, chat_id, message_id)`
- `tg.message_versions` уникален по `(message_fk, version_no)`

### WF30 — URL Normalizer (Message → content.urls + fetch job) (Message → content.urls + fetch job)

**Назначение:** принять URL, нормализовать, upsert `content.urls`, создать `content.url_fetches` через job.

**Trigger:** Execute Workflow Trigger.

**Input:**

```json
{
  "req": {
    "tenant_id": "<uuid>",
    "url": "<string>",
    "ctx": { "chat_id": "<bigint|null>", "visibility": "group|dm_private", "dm_owner_user_id": "<bigint|null>", "message_version_id": "<bigint|null>" }
  }
}
```

**Output:** SuccessEnvelope:

```json
{ "data": { "url_id": 123, "normalized_url":"...", "fetch_job_id": 456 } }
```

**DB side-effects:**

- UPSERT: `content.urls`
- WRITE: `ops.jobs` (job\_type: url\_fetch)

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
- INSERT: `content.documents` (doc\_type=url)
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

- UPDATE: `tg.file_instances` (tg\_file\_path, last\_seen\_at)
- UPSERT: `content.blob_objects`
- INSERT: `content.documents` (doc\_type=file)
- WRITE: `ops.jobs` на extract/chunk/embed

---

### WF35 — Voice Probe (Wake-word detector / STT-lite)

**Назначение:** короткая расшифровка первых N секунд voice, чтобы понять, есть ли обращение к ассистенту/команда (wake-word) и стоит ли делать полную транскрипцию.

**Trigger:** Execute Workflow Trigger (job).

**Input:**

```json
{
  "req": {
    "tenant_id": "<uuid>",
    "message_version_id": 1001,
    "document_id": 101,
    "wake_name": "<string>",
    "max_seconds": 5,
    "language": "<string|null>",
    "trace_id": "<string|null>"
  }
}
```

**Output:** SuccessEnvelope:

```json
{ "data": { "wake_detected": true, "confidence": 0.9, "probe_text": "...", "next_action": "transcribe_full|ignore" } }
```

**DB side-effects (по `SQL.txt`):**

- UPDATE: `content.documents.meta.voice_probe` (json) + `updated_at`
- `content.documents.status` **не переводить в `succeeded`** (probe — вспомогательный шаг)

---

### WF34 — Voice Transcriber (Full STT)

**Назначение:** полная расшифровка voice (или аудио), сохранение транскрипта как основного поискового текста документа.

**Trigger:** Execute Workflow Trigger (job).

**Input:**

```json
{
  "req": {
    "tenant_id": "<uuid>",
    "message_version_id": 1001,
    "document_id": 101,
    "language": "<string|null>",
    "trace_id": "<string|null>"
  }
}
```

**Output:** SuccessEnvelope:

```json
{ "data": { "transcript": "...", "token_count": 123, "document_id": 101 } }
```

**DB side-effects (по `SQL.txt`):**

- UPDATE: `content.documents`:
  - `text` = transcript (поиск/цитирование)
  - `status` = `succeeded`
  - `token_count`, `language`, `meta.transcript`/`meta.segments?`
- WRITE: `ops.jobs` → `chunk_document` → `embed_chunks` (если policy `allow_embedding=true`)

### WF33 — Extractor (documents.pending → documents.text)

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

- UPDATE: `content.documents` (text, text\_sha256, token\_count, status, error)
- WRITE: `ops.jobs` на chunk/embed (если policy allow\_embedding=true)

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

- INSERT/UPSERT: `kg.chunks` (idempotent по (document\_id, chunk\_no))
- WRITE: `ops.jobs` на embed

---

### WF41 — Embedder (kg.chunks → kg.chunk\_embeddings\_1536)

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
- UPSERT: `kg.chunk_embeddings_1536` (PK chunk\_id+model\_id)

---

### WF50 — QA Session Upserter (audit.qa\_sessions)

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

- UPSERT/UPDATE: `audit.qa_sessions` (last\_at, meta)

---

### WF51 — Answerer (Mention/DM question → answer + citations)

**Назначение:** принять вопрос, проверить ACL через WF00c, сделать retrieval (pgvector + joins), сформировать ответ с цитатами/ссылками, записать audit и отправить ответ в Telegram.

**Trigger:** Execute Workflow Trigger (job) или вызов из worker по контракту.

**Input:**

```json
{
  "req": {
    "tenant_id":"<uuid>",
    "tg_user_id":123,
    "channel":"group|dm",
    "chat_id":456,
    "question":"<text>",
    "question_message_version_id":1001,
    "trace_id":"<string|null>"
  }
}
```

**Retrieval scope (обязательный инвариант):**

- `channel=group`: источники **только** `chat_id` вопроса.
- `channel=dm`: источники = DM владельца + все чаты, где пользователь current member (`tg.chat_memberships_current`) и чат разрешён политикой.

**Output:** SuccessEnvelope:

```json
{
  "data": {
    "session_id":"<uuid>",
    "turn_id":555,
    "answer_text":"...",
    "citations":[{"rank":1,"chunk_id":77,"score":0.82,"snippet":"...","source_ref":{}}]
  }
}
```

**DB side-effects:**

- CALL: WF00c (required) → ctx.is\_allowed + ctx.visibility/chat\_policy
- READ: `kg.chunk_embeddings_1536` + join `kg.chunks` + join `content.documents` (с ACL-фильтрами)
- WRITE: `audit.qa_sessions`, `audit.qa_turns`, `audit.qa_citations`
- I/O: Telegram sendMessage/editMessageText (ответ в чат/личку)

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
- UPDATE: `ops.jobs` status/attempts/next\_run\_at
- CALL: WF20/WF31/WF32/WF33/WF40/WF41/WF51

---

### WF98 — Platform Error Catcher (n8n Error Workflow fallback)

**Назначение:** «последний рубеж» обработки ошибок на уровне n8n Error Workflow. Запускается, когда execution завершился ошибкой (неуправляемый сбой) или когда основной WF завершился StopAndError.

**Trigger:** Error Trigger.

**Input:** payload Error Trigger (структура n8n), минимум:

- исходный workflow/execution id
- error message/stack/details

**Output:** SuccessEnvelope (всегда, чтобы не создавать каскад ошибок):

```json
{ "data": { "correlation_id":"<uuid>", "dedup_skipped": false, "wf99_called": true } }
```

**Dedup guard (обязателен):**

- Перед вызовом WF99 проверить `ops.errors` по `correlation_id`.
- Если запись уже есть — **не вызывать WF99** (`dedup_skipped=true`).

**DB side-effects:**

- OPTIONAL READ: `ops.errors` (dedup)
- CALL: WF99 (только если не dedup)

### WF99 — Global ERR Handler

**Назначение:** единый обработчик ошибок (ErrorPipe Contract v1): нормализация ошибки → запись в `ops.errors` **всегда** → (опционально) фиксация job failure → возврат канонического ErrorEnvelope. fileciteturn20file0

**Trigger:** Execute Workflow Trigger (sub-workflow).

**Input (ErrorPipe Contract v1):** WF99 обязан корректно обработать любой из вариантов:

- `ctx` (object, опционально)
  - `ctx.correlation_id` (uuid, может отсутствовать → WF99 генерирует)
  - `ctx.job_id` (number, может отсутствовать)
- `error_context` (object, рекомендуется)
  - `node` (string, точное имя ноды-источника)
  - `operation` (string: select/insert/update/delete/upsert)
  - `table` (string: schema.table)
  - `correlation_id` (uuid, дублирование)
  - `error_message` (string)
  - `status_code` (number)
- сырые поля error output / upstream (как есть, опционально):
  - `message` (string)
  - `description` (string)
  - `error` (object)
  - `n8nDetails` (object)
  - любые иные поля

**Выход:** ErrorEnvelope v1 (канонический), `meta.source="WF99"`, `error.details` — объект. fileciteturn20file0

**DB side-effects:**

- INSERT **всегда** (best-effort): `ops.errors` (детали как json/jsonb объекты, без stringify). fileciteturn20file0
- Если `ctx.job_id` задан:
  - UPDATE `ops.jobs` (status='failed' и связанные поля по схеме)
  - INSERT `ops.job_runs` (с фиксацией ошибки)
- Если `ctx.job_id` отсутствует — job-path **не выполняется**.

**Инварианты:**

- `correlation_id` переиспользуется: если пришёл во входе — не заменять.
- Если запись в `ops.errors` не удалась — WF99 не должен падать; в выходе пометить `_internal.persist_failed=true`. fileciteturn20file0

## 2) Правило эволюции контрактов

1. Любой новый workflow добавляется в этот документ отдельной секцией.
2. Любое изменение контрактов — через версионирование полей (добавление — ок, удаление/переименование — только с миграцией и указанием даты).
3. Все меж-WF вызовы должны передавать **минимальный payload** согласно контракту.

---

## 3) Минимальный набор данных для "ответа со ссылками"

Чтобы бот мог отвечать аргументированно и с источниками, цепочка должна обеспечивать:

- `tg.message_versions` хранит оригинальный payload и text/caption (и normalized\_text)
- `content.documents` хранит извлечённый текст/мета + связи с message\_version/url/file
- `kg.chunks` хранит чанки текста, привязанные к document\_id
- `kg.chunk_embeddings_1536` хранит embeddings чанков
- `audit.qa_turns`/`audit.qa_citations` фиксируют Q/A и ссылки на chunk\_id + snippet/source\_ref

Это и есть минимально достаточный контур "knowledge bot".

