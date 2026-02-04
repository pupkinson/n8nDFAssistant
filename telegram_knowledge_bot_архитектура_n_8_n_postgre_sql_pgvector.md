# Telegram Knowledge Bot — Архитектура (n8n + PostgreSQL + pgvector)

## 1) Цель

Сделать Telegram‑бота, который:

- автоматически собирает знания из корпоративных Telegram‑чатов (сообщения, файлы, ссылки, медиа);
- строит доказуемые ответы (с источниками) на вопросы пользователей;
- соблюдает приватность и права доступа (группа/личка/админ);
- устойчив к сбоям и масштабируется.

## 2) Ключевые сценарии (User Stories)

1. **Индексация чатов**: бот добавлен в выбранные группы, фиксирует весь поток сообщений и вложений.
2. **Поиск/вопрос**: пользователь упоминает бота в группе или пишет в личку → получает ответ с цитатами и ссылками на источники.
3. **Контроль доступа**: пользователь видит только то, на что у него есть право (по чатам и приватным диалогам).
4. **Администрирование**: админ управляет allowlist пользователей, списком индексируемых чатов, политиками хранения/приватности.
5. **Обработка вложений/ссылок**: бот скачивает документы/страницы, извлекает содержимое, индексирует и привязывает к исходному сообщению.
6. **Аудит**: фиксируются запросы к боту, использованные источники, ошибки обработки.

## 2.6) Модель общения и триггеры ответа (DM vs Group)

### 2.6.1 DM (личная переписка)

- **Когда отвечает:** бот отвечает пользователю в личке на осмысленные сообщения, если пользователь в allowlist (`core.tenant_users.enabled=true`).
- **Какие источники может использовать:**
  - данные DM владельца (visibility=dm\_private, dm\_owner\_user\_id=user);
  - данные из всех чатов tenant, где пользователь является **текущим** участником (`tg.chat_memberships_current`) и чат разрешён политикой (`core.chat_policies`).

### 2.6.2 Group (публичные группы/чаты) (публичные группы/чаты)

- **Когда отвечает (строго):**
  1. есть mention `@<bot_username>` в `entities/caption_entities`, ИЛИ
  2. сообщение — reply на сообщение бота, ИЛИ
  3. команда `/command@<bot_username>` (если поддержка команд включена).
- **Какие источники может использовать:** только информация, ранее опубликованная \*\*в этом же \*\*\`\`. Запросы «принеси из другого чата/лички» в группе — отказ. Запросы «принеси из другого чата/лички» в группе — отказ.
- **Формат ответа:** публичный reply на сообщение обращения; допускается серия сообщений (пагинация/лимиты Telegram) и deep‑links на найденные сообщения.

### 2.6.3 Голосовые сообщения (STT): авто и по запросу

- Настройки (в `core.chat_policies` или эквивалент по SQL.txt):
  - `auto_transcribe_voice` (bool)
  - `assistant_name` / `wake_name` (string)
- **auto\_transcribe\_voice=true:** любое voice → job `voice_transcribe` → транскрипт в БД → reply транскриптом.
- **auto\_transcribe\_voice=false:** только по запросу:
  - текстом: reply на voice + mention + «расшифруй»;
  - голосом: voice с `wake_name` + просьба.

**Опциональная оптимизация (рекомендуется):**

- Чтобы не транскрибировать всё подряд в режиме OFF: `WF35 voice_probe` (2–5 сек для детекта wake) → если wake найден → `WF34 voice_transcribe`.

## 2.7) Авто-анализ мультимедиа и ссылок (обязательный контур знаний)

Требование: **любой** мультимедиа-объект (аудио/voice, видео, изображение, документ, ссылка) должен:

1. быть сохранён/привязан к исходному сообщению;
2. пройти **автоматический анализ**;
3. результаты анализа должны быть сохранены так, чтобы объект можно было искать **по смыслу**.

### 2.7.1 Что именно анализируем

- **Voice/Audio:** полная транскрипция (WF34), + при необходимости voice\_probe (WF35).
- **Video:** краткое описание происходящего (VLM/LLM), при возможности — сцены/таймкоды.
- **Image:** caption/описание + OCR (если есть текст).
- **Documents (PDF/DOCX/XLSX/сканы):** извлечённый текст + OCR для сканов; при возможности — структура (заголовки/таблицы).
- **URLs:** скачивание/парсинг readable text + title; при необходимости — краткое summary.

### 2.7.2 Где хранить результаты

Единый принцип:

- основной поисковый текст → `content.documents.text`
- структурированные результаты → `content.documents.meta` (JSON):
  - audio/voice: `meta.transcript`, `meta.language`, `meta.segments?`
  - video: `meta.description`, `meta.scenes?`, `meta.timestamps?`
  - image: `meta.caption`, `meta.ocr_text?`, `meta.objects?`
  - docs: `meta.extracted_text`, `meta.ocr_text?`, `meta.tables?`
  - url: `meta.page_text`, `meta.title`, `meta.summary?`

Далее всё идёт по общему контуру знаний: `chunk_document` → `embed_chunks` → поиск по смыслу.

## 3) Высокоуровневая схема

```
Telegram Groups/DM
      |
      v
[WF10 Telegram Ingest]  --->  RAW (updates)
      |
      v
[WF20 Normalize & Persist] ---> canonical (users/chats/messages/files/links)
      |
      +--> [WF30 Fetch Files] ----+
|                           |
+--> [WF31 Fetch Links] ----+--> [extract_text job router]
                                 |
                                 +--> [WF35 Voice Probe] (extract_kind=voice_probe)
                                 |
                                 +--> [WF34 Voice Transcribe] (extract_kind=voice_transcribe)
                                 |
                                 +--> [WF40 Content Extract] (extract_kind=doc_text|url_text)
                                 |
                                 +--> [WF42 Media Describe] (extract_kind=image_*|video_*)
                                      |
                                      v
                               [WF41 Chunk & Embed] (after `content.documents.text/meta` is available)
                                      |
                                      v
                               pgvector knowledge_index

User question
      |
      v
[WF50 Query Orchestrator]
  - ACL filter
  - hybrid retrieve
  - rerank (опц.)
  - answer with citations
      |
      v
Telegram Reply
```

## 4) Компоненты

### 4.1 Telegram Bot

- Режимы: групповой чат и личные сообщения.
- Требование: бот должен получать сообщения в группах (privacy mode/права бота — на стороне Telegram настроек).

**Поведение ответа:**

- DM: отвечает allowed‑пользователю; retrieval может охватывать все доступные чаты пользователя (по membership).
- Group: отвечает только при mention/reply-to-bot/command; retrieval ограничен текущим `chat_id`.

**Голосовые (STT):**

- При включённой политике `auto_transcribe_voice` бот автоматически расшифровывает voice и отвечает транскриптом.
- При выключенной политике — расшифровка только по запросу (в т.ч. voice‑запрос с `wake_name`).

### 4.2 Оркестратор: n8n

- Все интеграции/логика пайплайнов выполняются workflow.
- Минимизировать Code node; сбор структур через Set (dotNotation), Merge, IF/Switch, Split in Batches.
- Используем **2×MCP** (см. единый регламент проекта):
  - `n8n-mcp`
  - второй MCP сервера проекта

**Основной механизм ошибок (обязательный): ErrorPipe Contract v1**

- Ошибки I/O обрабатываются строго по **ErrorPipe Contract v1**:
  - На каждой Postgres/HTTP/Telegram ноде: **On Error: Continue using error output**
  - Error output → `ERR — Source <NodeName>` (includeOtherFields=true, `_err.node/_err.operation/_err.table`) + приклейка `ctx`
  - затем `ERR — Prepare ErrorPipe v1` → **Execute Workflow (WF99)** → **StopAndError**
  - **ErrorEnvelope формирует только WF99**.

**Последний рубеж (рекомендуется): n8n Error Workflow (fallback)**

- Для критических «неуправляемых» падений execution (ошибка конфигурации ноды, внутреннее исключение n8n и т.п.) включаем **workflow-level Error Workflow**.
- Error Workflow запускает отдельный workflow **WF98 — Platform Error Catcher** (с нодой **Error Trigger**).
- WF98 обязан:
  - сформировать минимальный `ctx` (workflow="WF98", correlation\_id, ts, execution\_id, исходный workflow\_name),
  - сформировать `error_context` из payload Error Trigger,
  - **сделать дедуп-guard по correlation\_id**: перед вызовом WF99 проверить `ops.errors` и пропустить WF99, если ошибка уже залогирована,
  - иначе вызвать **WF99** и завершиться.
- Важно: Error Workflow **не заменяет** ErrorPipe v1, а только страхует случаи, когда ErrorPipe не успел отработать.

### 4.3 Хранилище: PostgreSQL + pgvector

- Хранит:
  - канонические сущности (сообщения, авторы, чаты, вложения);
  - извлечённый текст/метаданные файлов и ссылок;
  - чанки и эмбеддинги;
  - аудит запросов и журнал ошибок.

### 4.4 LLM/Embedding: Google Gemini API

- Разделяем:
  - модель **генерации** ответов;
  - модель **эмбеддингов**.
- Версии и идентификаторы моделей фиксируются в БД (для воспроизводимости и переиндексации).

### 4.5 Хранилище файлов (рекомендуется)

- В БД хранить **метаданные** и контрольные суммы.
- Бинарные файлы хранить во внешнем object storage (S3/MinIO) или файловой системе сервера.

## 5) Данные и сущности (сопоставление с текущей DDL)

**Источник истины по именам схем/таблиц/колонок — файл ********SQL.txt********.**

### 5.1 Core (тенантность, боты, доступ, политики)

- `core.tenants` — тенанты (организации/контуры).
- `core.bots` — зарегистрированные боты.
- `core.bot_transport_config` / `core.bot_transport_state` — настройки и текущее состояние транспорта (webhook/polling).
- `core.tenant_users` — allowlist пользователей + роли (user/admin) в рамках tenant.
- `core.tenant_chats` — чаты, известные системе (на уровне tenant).
- `core.chat_policies` — политика индексации/видимости/retention для чатов.

### 5.2 RAW (сырые апдейты Telegram)

- `raw.telegram_updates` — все входящие updates (body + headers + body\_sha256) для аудита и повторной обработки.
- `raw.telegram_update_keys` — таблица ключей для дедупликации по `(bot_id, update_id)`.

### 5.3 Telegram Canonical (нормализованные сущности)

- `tg.users` — пользователи Telegram (по `tg_user_id`).
- `tg.chats` — чаты Telegram (по `chat_id`).
- `tg.chat_member_events` — события членства/ролей (join/leave/promote/…): история.
- `tg.chat_memberships_current` — текущее состояние членства пользователя в чате (для ACL).
- `tg.messages` — «шапка» сообщения (identity: `tenant_id + chat_id + message_id`) + `visibility` и (для DM) `dm_owner_user_id`.
- `tg.message_versions` — версии содержимого сообщения (текст/caption/entities/…); `tg.messages.current_version_id` указывает на актуальную.
- `tg.message_attachments` — вложения, привязанные к конкретной версии сообщения.
- `tg.files` / `tg.file_instances` — метаданные файлов и наблюдения file\_id↔unique\_id↔tg\_file\_path.

### 5.4 Content + Knowledge (извлечённый контент, чанки, эмбеддинги)

- `content.urls` — нормализованные URL (уникализация ссылок).
- `content.url_fetches` — попытки скачивания URL (статус/ошибки/контент‑хэш/сырые метаданные).
- `content.blob_objects` — объектное хранилище/контейнер метаданных бинарей (sha256/size/mime/storage locator).
- `content.documents` — канонический «документ для RAG», собирается из:
  - `tg.message_versions` (текст сообщений),
  - `tg.files` (извлечённый текст из файлов),
  - `content.url_fetches` (текст со страниц). Документ содержит `tenant_id`, контекст (`chat_id`, опц. `message_version_id`/`file_unique_id`/`url_id`), а также признаки приватности/видимости.
- `kg.embedding_models` — реестр моделей эмбеддинга (provider/model\_key/dim/task).
- `kg.chunks` — чанки документов (включая `tsv` для гибридного поиска).
- `kg.chunk_embeddings_1536` — эмбеддинги чанков (pgvector), привязанные к `model_id`.

### 5.5 Audit + Ops (вопросы/ответы, очередь, ошибки, телеметрия)

- `audit.qa_sessions` / `audit.qa_turns` / `audit.qa_citations` — история диалогов с ботом и «доказательная база» (какие чанки использованы).
- `ops.jobs` / `ops.job_runs` — очередь фоновых задач и исполнения (heavy work: fetch/extract/embed/reindex).
- `ops.errors` — единый журнал ошибок (целевая запись WF99).
- `ops.webhook_health_snapshots` — снимки состояния webhook (для watchdog).
- `ops.bot_transport_events` — события переключения режима/сбои транспорта.

## 6) Политика доступа (ACL) — как реально enforced в текущей схеме

### 6.1 Принцип

- Ответ формируется **только из разрешённых документов/сообщений**.
- ACL применяется **до** генерации (на шаге retrieval/select), а не после.

### 6.2 Правила (минимальный базис)

1. Пользователь должен быть в `core.tenant_users` и `enabled = true`.
2. Для группового контента:
   - чат должен быть разрешён в `core.chat_policies` (индексация/видимость),
   - пользователь должен быть текущим участником чата по `tg.chat_memberships_current` (status != left/kicked),
   - источники ограничиваются `content.documents` в этом чате (и/или `tg.messages.visibility='group'`).
3. Для лички (DM):
   - доступ к документам DM имеет только владелец (`dm_owner_user_id`) и админ (`core.tenant_users.role='admin'`).
4. При выходе пользователя из чата:
   - доступ к знаниям этого чата исчезает автоматически, так как retrieval фильтруется по `tg.chat_memberships_current`.

### 6.3 Техническое правило retrieval

- Все выборки кандидатов для RAG делаются через **Postgres node (select)** с фильтрами минимум по: `tenant_id`, допустимым `chat_id` (если group), и `dm_owner_user_id`/role (если DM).
- Любые ошибки I/O проходят через **ErrorPipe Contract v1 → WF99**.

## 7) Пайплайны обработки

## 7.0) Ops Jobs — единый каталог `ops.job_type` и контракт payload

Источник истины по перечислению типов: `telegram_knowledge_bot_schema.sql` / `SQL.txt`.

### 7.0.1 Базовые принципы

- `ops.jobs.job_type` — **строго enum**:
  - `normalize_update`
  - `upsert_membership`
  - `fetch_tg_file`
  - `fetch_url`
  - `build_document`
  - `extract_text`
  - `chunk_document`
  - `embed_chunks`
  - `answer_query`
  - `reembed_model_migration`
- Расширение поведения делаем **не через новые job\_type**, а через `payload.kind/mode` (например, `extract_text` покрывает voice/image/video/docs/url).
- `ops.jobs.correlation_id` — основной ключ сквозной трассировки. Любые дочерние jobs наследуют `correlation_id` родителя.
- В `payload` **не stringify JSON**: всегда объект.
- Idempotency: каждый job обязан иметь детерминированные ключи в payload (например `raw_update_id` или `document_id`), чтобы воркеры могли делать safe-upsert и избегать дубликатов.

### 7.0.2 Общий payload (минимальный слой)

Минимум, который должен быть в payload у большинства jobs:

- `tenant_id` (uuid)
- `bot_id` (uuid)
- `trace_id` (string|null)
- `correlation_id` (uuid) — обычно берём из `ops.jobs.correlation_id`, но можно дублировать для удобства
- `visibility` (`group|dm_private|admin_only`)
- `chat_id` (bigint|null)
- `message_version_id` (bigint|null)

### 7.0.3 Контракты payload по `job_type`

**A) normalize\_update** (WF20)

- `raw_update_id` (bigint) **или** `(update_id, received_at, request_id)`
- `update_type` (string)

**B) upsert\_membership** (WF20 или отдельный worker)

- `chat_id` (bigint)
- `tg_user_id` (bigint)
- `event_type` (join/leave/promote/…)
- `raw_update_id` (bigint)

**C) fetch\_tg\_file** (WF30)

- `tg_file_id` (string)
- `file_unique_id` (string)
- `file_kind` (voice|audio|video|photo|document|sticker|…)
- `message_version_id` (bigint)

**D) fetch\_url** (WF31)

- `url_id` (bigint)
- `url` (string)
- `message_version_id` (bigint)

**E) build\_document** (WF20/WF30/WF31)

- `doc_type` (`message|file|url`)
- `source_ref` (object) — один из:
  - `{ "message_version_id": <id> }`
  - `{ "file_unique_id": "..." }`
  - `{ "url_id": <id> }`
- `chat_id`, `visibility`, `dm_owner_user_id?`

**F) extract\_text** (WF34/WF35/WF40/WF42 routed)

- `document_id` (bigint)
- `extract_kind` (string, обязателен), например:
  - `voice_probe` (WF35)
  - `voice_transcribe` (WF34)
  - `doc_text` (WF40)
  - `url_text` (WF40)
  - `image_caption` / `image_ocr` (WF42)
  - `video_describe` (WF42)
  - `audio_transcribe` (WF34)
- `source_locator` (object):
  - для file/audio/video/image: `{ "blob_object_id": <id>, "mime": "..." }`
  - для url: `{ "url_fetch_id": <id> }`
- `language_hint` (string|null)
- `max_seconds` (int|null) — только для `voice_probe`

**G) chunk\_document** (WF41)

- `document_id` (bigint)
- `strategy` (string|null)

**H) embed\_chunks** (WF41)

- `document_id` (bigint)
- `embedding_model_id` (bigint)

**I) answer\_query** (WF50/WF51)

- `channel` (`group_chat|dm`)
- `chat_id` (bigint)
- `tg_user_id` (bigint)
- `question` (string)
- `question_message_version_id` (bigint|null)

**J) reembed\_model\_migration** (WF92/WF41)

- `from_model_id` (bigint)
- `to_model_id` (bigint)
- фильтры: `tenant_id`, `chat_id?`, `doc_type?`, `since?`, `until?`

### 7.0.4 Роутинг jobs → workflow

- `normalize_update` → WF20
- `fetch_tg_file` → WF30
- `fetch_url` → WF31
- `build_document` → WF20 (message) / WF30 (file) / WF31 (url)
- `extract_text` → Switch по `payload.extract_kind`:
  - `voice_probe` → WF35
  - `voice_transcribe` / `audio_transcribe` → WF34
  - `doc_text` / `url_text` → WF40
  - `image_*` / `video_*` → WF42
- `chunk_document` / `embed_chunks` → WF41
- `answer_query` → WF50 → WF51
- `reembed_model_migration` → WF92 (batch) → WF41

---

### 7.1 Ingest (Telegram → RAW)

- Вход: webhook updates.
- Дедупликация по update\_id + (chat\_id, message\_id).
- Сохранение сырого update в RAW таблицу (для повторной обработки).

### 7.2 Normalize (RAW → Canonical)

- Upsert users/chats.
- Upsert memberships (на основе service‑событий/снимков/ручной синхронизации).
- Upsert messages.
- Выделение:
  - вложений (documents, photos, videos, voice, etc.);
  - ссылок (url entities);
  - редактирований (edited\_message) как новая версия.

**Interaction routing (когда отвечать):**

- На этапе Normalize определяется `should_respond`:
  - DM: практически всегда (если пользователь allowed),
  - Group: только mention/reply-to-bot/command.

**Постановка задач (ops.jobs):**

- Normalize не отвечает сам, а создаёт jobs на универсальный анализ:
  - `fetch_tg_file` / `fetch_url`
  - `build_document`
  - `extract_text` (универсальный анализ):
    - voice/audio → transcript
    - video → description/scenes
    - image → caption + OCR
    - docs → extracted text (+ OCR)
    - url → page text (+ title)
  - `chunk_document` → `embed_chunks`
  - `answer_query` (если нужно ответить)

### 7.3 Enrich (files/links)

- Файлы:
  - получить tg file\_path → скачать → посчитать sha256 → загрузить в storage → сохранить метаданные.
- Ссылки:
  - скачать html/контент → извлечь readable text → sha256.

**Важно:** enrich отвечает только за доставку контента. Смысловой анализ выполняется в Extract/Describe воркерах.

### 7.4 Extract/Describe → Chunk → Embed

Смысловой анализ строится вокруг `ops.jobs.job_type='extract_text'` и параметра `payload.extract_kind`.

- Extract/Describe (универсальный анализ мультимедиа):
  - voice/audio → `extract_kind=voice_probe|voice_transcribe|audio_transcribe` (WF35/WF34)
  - image → `extract_kind=image_caption|image_ocr` (WF42)
  - video → `extract_kind=video_describe` (WF42)
  - docs → `extract_kind=doc_text` (WF40)
  - url → `extract_kind=url_text` (WF40)

**Единое правило хранения результата:**

- основной поисковый текст → `content.documents.text`

- доп. структура → `content.documents.meta` (JSON)

- Chunk:

  - `chunk_document` (WF41): чанкинг по структуре; хранить `chunk_index` + метаданные.

- Embed:

  - `embed_chunks` (WF41): эмбеддинг для каждого chunk; фиксировать `embedding_model_id`.

### 7.5 Query (вопрос → ответ)

- Триггер ответа:
  - DM: любое осмысленное сообщение allowed‑пользователя.
  - Group: mention/reply-to-bot/command.
- Определить контекст:
  - group chat question → источники только этого `chat_id`.
  - DM question → источники лички владельца + все чаты, где пользователь current member и чат разрешён политикой.
- Retrieval:
  - hybrid: текстовый поиск + векторный поиск → объединение top‑K.
- Rerank (опционально): LLM‑ранжирование top‑N.
- Generation:
  - ответ + список источников (message links, doc refs, цитаты).
- Audit:
  - записать question/answer/sources.

## 8) Каталог workflow (n8n)

### Базовые

- **WF10 — Telegram Ingest (Webhook Receiver)**
  - принимает updates, пишет RAW, ставит задачи в `ops.jobs`.
- **WF11 — Bot Transport Watchdog**
  - мониторит webhook/polling, фиксирует состояние транспорта.
- **WF20 — Normalize & Persist**
  - читает RAW/`ops.jobs`, пишет canonical, определяет `should_respond`, ставит jobs на универсальный media/URL анализ.
- **WF30 — File Fetcher**
  - скачивание файлов Telegram, дедуп по sha256.
- **WF31 — Link Fetcher**
  - скачивание страниц, дедуп.
- **WF35 — Voice Probe**
  - короткий STT (2–5 сек) для детекта wake-слова/команды (используется когда `auto_transcribe_voice=false`).
- **WF34 — Voice Transcriber (Full STT)**
  - полная расшифровка voice/audio, сохранение транскрипта как `content.documents.text` + опциональный reply.
- **WF42 — Media Describe (Image/Video/Audio)**
  - описание изображений/видео (caption/scene summary), OCR, метаданные — сохраняется в `content.documents`.
- **WF40 — Content Extractor**
  - извлечение текста из документов/страниц (PDF/DOCX/HTML) + нормализация.
- **WF41 — Chunk & Embed**
  - чанкинг + эмбеддинги + запись в pgvector.
- **WF50 — Query Orchestrator (ACL-first retrieval)**
  - готовит retrieval scope, вызывает генератор ответа.
- **WF51 — Answerer (Answer with citations)**
  - генерация ответа + цитаты/ссылки, запись audit, отправка в Telegram.

### Администрирование и поддержка

- **WF60 — Admin Panel (Telegram commands)**
  - allowlist, chat policies, статус очередей, переиндексация.
- **WF90 — Job Runner (ops.jobs executor)**
  - выбирает и исполняет задачи очереди, пишет `ops.job_runs`.
- **WF92 — Reindex/Reprocess (batch jobs)**
  - массовая переобработка по фильтрам (чат/период/модель эмбеддинга) через постановку задач в `ops.jobs`.
- **WF98 — Platform Error Catcher (n8n Error Workflow)**
  - стартует от **Error Trigger** как workflow-level Error Workflow.
  - предназначен для «неуправляемых» падений execution, которые обходят ErrorPipe.
  - нормализует минимальный `ctx`/`error_context` и вызывает **WF99**.
- **WF99 — Global ERR Handler (ErrorPipe Contract v1)**
  - единая нормализация ошибок + запись в `ops.errors` (best-effort) + опциональный job-path (только если есть `ctx.job_id`).

## 9) Ошибки, корреляция, идемпотентность

- Каждое событие/задача несёт **correlation\_id**.

**Основной путь ошибок (обязательный): ErrorPipe v1 → WF99**

- Любая I/O ошибка обрабатывается по **ErrorPipe Contract v1**:
  - error output → `ERR — Source <NodeName>` (includeOtherFields=true, `_err.*`) + приклейка `ctx`
  - `ERR — Prepare ErrorPipe v1` → Execute Workflow (WF99) → StopAndError
  - **ErrorEnvelope возвращает только WF99**.

**Fallback (последний рубеж): n8n Error Workflow → WF98 → WF99**

- Если execution падает «неуправляемо» (обходя ErrorPipe), срабатывает workflow-level Error Workflow и запускает **WF98**, который передаёт ошибку в **WF99**.

- Все критичные записи — **upsert** по естественным ключам.

- Повторная обработка безопасна (at-least-once delivery).

## 10) Масштабирование

- Разнести ingest и тяжелую обработку (extract/embed) по очереди ops\_jobs.
- Split in Batches + лимиты параллельности.
- Индексы:
  - btree по (chat\_id, message\_id), timestamps;
  - pgvector индекс для embeddings;
  - полнотекст (tsvector) для hybrid.
- Ротация RAW/логов по retention.

## 11) Безопасность и приватность

- Секреты хранятся в n8n Credentials.
- Шифрование хранения файлов (по возможности на уровне storage).
- Политика retention и удалений (per chat/per DM).
- Anti‑prompt‑injection: внешние документы не могут управлять инструментами бота.

## 12) Backlog (следующие усиления)

- Автовыделение решений/поручений (facts layer) и таймлайны.
- Дайджесты по проектам и алерты.
- Реранкер и улучшенный hybrid retrieval.
- Экспорт/удаление данных пользователя (комплаенс).

---

## Договорённости (фиксируем как правила проекта)

1. Слои данных: RAW → Canonical → Knowledge → Facts → Audit.
2. ACL применяется **до** генерации ответов.
3. Основной механизм ошибок: **ErrorPipe Contract v1 → WF99** (error output + `ERR — Source` + `ERR — Prepare ErrorPipe v1` + Execute WF99 + StopAndError).
4. Дополнительный последний рубеж: **n8n Error Workflow → WF98 (Error Trigger) → WF99** для «неуправляемых» падений execution.
5. Минимизировать Code node, по максимуму собирать логику стандартными нодами.

