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
      +--> [WF31 Fetch Links] ----+--> [WF40 Extract Content]
                                      |
                                      v
                               [WF41 Chunk & Embed]
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

### 4.2 Оркестратор: n8n

- Все интеграции/логика пайплайнов выполняются workflow.
- Минимизировать Code node; сбор структур через Set (dotNotation), Merge, IF/Switch, Split in Batches.
- Используем **2×MCP** (см. единый регламент проекта):
  - `n8n-mcp`
  - второй MCP сервера проекта
- Ошибки I/O обрабатываются строго по **ErrorPipe Contract v1**:
  - На каждой Postgres/HTTP/Telegram ноде: **On Error: Continue using error output**
  - Error output → `ERR — Source <NodeName>` (includeOtherFields=true, `_err.node/_err.operation/_err.table`) + приклейка `ctx`
  - затем `ERR — Prepare ErrorPipe v1` → **Execute Workflow (WF99)** → **StopAndError**
  - **ErrorEnvelope формирует только WF99**.

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

**Источник истины по именам схем/таблиц/колонок — файл **``**.** Ниже — логическая группировка данных *в терминах реально существующих таблиц*.

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

### 7.3 Enrich (files/links)

- Файлы:
  - получить tg file\_path → скачать → посчитать sha256 → загрузить в storage → сохранить метаданные.
- Ссылки:
  - скачать html/контент → извлечь readable text → sha256.

### 7.4 Extract → Chunk → Embed

- Extract:
  - нормализация текста, язык, структура (заголовки/таблицы где возможно).
- Chunk:
  - чанкинг по структуре; хранить chunk\_index + метаданные.
- Embed:
  - эмбеддинг для каждого chunk; фиксировать embedding\_model.

### 7.5 Query (вопрос → ответ)

- Определить контекст:
  - group chat question → источники только этого чата (и зависимых, если политика разрешает).
  - DM question → источники лички владельца + разрешённые чаты.
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
  - читает RAW/`ops.jobs`, пишет canonical.
- **WF30 — File Fetcher**
  - скачивание файлов Telegram, дедуп по sha256.
- **WF31 — Link Fetcher**
  - скачивание страниц, дедуп.
- **WF40 — Content Extractor**
  - извлечение текста из файлов/страниц.
- **WF41 — Chunk & Embed**
  - чанкинг + эмбеддинги + запись в pgvector.
- **WF50 — Query Orchestrator (Answer with citations)**
  - принимает вопрос, делает retrieval (ACL-first), генерирует ответ, возвращает в Telegram.

### Администрирование и поддержка

- **WF60 — Admin Panel (Telegram commands)**
  - allowlist, chat policies, статус очередей, переиндексация.
- **WF90 — Job Runner (ops.jobs executor)**
  - выбирает и исполняет задачи очереди, пишет `ops.job_runs`.
- **WF92 — Reindex/Reprocess (batch jobs)**
  - массовая переобработка по фильтрам (чат/период/модель эмбеддинга) через постановку задач в `ops.jobs`.
- **WF99 — Global ERR Handler (ErrorPipe Contract v1)**
  - единая нормализация ошибок + запись в `ops.errors` (best-effort) + опциональный job-path (только если есть `ctx.job_id`).

## 9) Ошибки, корреляция, идемпотентность

- Каждое событие/задача несёт **correlation\_id**.
- Любая I/O ошибка обрабатывается по **ErrorPipe Contract v1**:
  - error output → `ERR — Source <NodeName>` (includeOtherFields=true, `_err.*`) + приклейка `ctx`
  - `ERR — Prepare ErrorPipe v1` → Execute Workflow (WF99) → StopAndError
  - **ErrorEnvelope возвращает только WF99**.
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
3. Все Postgres nodes обрабатывают ошибки через error output и общий ERR handler.
4. Минимизировать Code node, по максимуму собирать логику стандартными нодами.

