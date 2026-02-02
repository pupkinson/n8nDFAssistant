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
- Все Postgres nodes — **On Error: Continue using error output** → единый ERR handler.

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

## 5) Данные и сущности (логическая модель)
### 5.1 Canonical слой
- **tg_users**: telegram_user_id, username, first_name, last_name, is_bot, created_at, updated_at
- **tg_chats**: telegram_chat_id, type, title, created_at, updated_at
- **tg_memberships**: chat_id, user_id, role, joined_at, left_at, is_current
- **tg_messages**: chat_id, message_id, sent_at, sender_user_id, text, raw_json, is_edited, edited_at, reply_to_message_id, thread_id
- **tg_files**: file_id (tg), unique_id, mime_type, file_name, file_size, telegram_file_path, storage_url, sha256, status
- **tg_links**: url, normalized_url, domain, fetched_at, status, sha256_content
- **tg_message_attachments**: message_pk -> file/link references

### 5.2 Knowledge слой (RAG)
- **kg_documents**: doc_id, source_type (message/file/link), source_ref, title, extracted_text, language, extracted_at
- **kg_chunks**: chunk_id, doc_id, chunk_index, chunk_text, token_count, metadata_json
- **kg_embeddings**: chunk_id, embedding vector, embedding_model, created_at
- Индексы: pgvector (cosine/inner product), плюс текстовые (tsvector) для гибридного поиска.

### 5.3 Facts слой (опционально, но желательно)
- **fact_decisions**: decision_id, chat_id, message_id, decided_at, summary, approver_user_id, related_entities_json
- **fact_tasks**: task_id, chat_id, message_id, created_at, assignee_user_id, due_at, status, summary

### 5.4 Access/Policy слой
- **acl_allowlist_users**: user_id, role (user/admin), enabled
- **acl_chat_policies**: chat_id, is_indexed, visibility (members/admin_only), retention_days
- **acl_private_policies**: dm_chat_id, owner_user_id, visibility (owner+admin)

### 5.5 Audit/ops слой
- **audit_queries**: query_id, asked_by_user_id, chat_context, question_text, answer_text, sources_json, created_at
- **ops_jobs**: job_id, type, payload_json, status, attempts, last_error, created_at, updated_at
- **ops_errors**: error_id, correlation_id, workflow, node, error_kind, message, details_json, created_at

> Примечание: физическую DDL‑схему оформим отдельно (как следующий артефакт), но логика слоёв фиксируется здесь.

## 6) Политика доступа (ACL)
### 6.1 Принцип
- Ответ формируется **только из разрешённых источников**.
- Источник = сообщение/документ/ссылка + привязка к чату.

### 6.2 Правила
1. Пользователь должен быть:
   - в allowlist (включён), иначе бот молчит/возвращает отказ.
2. Для группового контента:
   - пользователь должен быть **текущим участником чата** (membership.is_current = true),
   - и чат должен быть разрешён для индексирования (acl_chat_policies.is_indexed = true).
3. Для лички:
   - доступ к данным личной переписки имеет только владелец (owner_user_id) и администратор.
4. При выходе пользователя из чата:
   - доступ к знаниям этого чата у пользователя должен исчезать (по membership.left_at/is_current).

### 6.3 Техническая реализация enforcement
- Все retrieval‑запросы выполняются через параметризованные SQL (user_id + контекст чат/DM).
- Критичный принцип: **ACL применяется до генерации** (на шаге выборки кандидатов).

## 7) Пайплайны обработки
### 7.1 Ingest (Telegram → RAW)
- Вход: webhook updates.
- Дедупликация по update_id + (chat_id, message_id).
- Сохранение сырого update в RAW таблицу (для повторной обработки).

### 7.2 Normalize (RAW → Canonical)
- Upsert users/chats.
- Upsert memberships (на основе service‑событий/снимков/ручной синхронизации).
- Upsert messages.
- Выделение:
  - вложений (documents, photos, videos, voice, etc.);
  - ссылок (url entities);
  - редактирований (edited_message) как новая версия.

### 7.3 Enrich (files/links)
- Файлы:
  - получить tg file_path → скачать → посчитать sha256 → загрузить в storage → сохранить метаданные.
- Ссылки:
  - скачать html/контент → извлечь readable text → sha256.

### 7.4 Extract → Chunk → Embed
- Extract:
  - нормализация текста, язык, структура (заголовки/таблицы где возможно).
- Chunk:
  - чанкинг по структуре; хранить chunk_index + метаданные.
- Embed:
  - эмбеддинг для каждого chunk; фиксировать embedding_model.

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
  - принимает updates, пишет RAW, ставит задачи в ops_jobs.
- **WF20 — Normalize & Persist**
  - читает RAW/ops_jobs, пишет canonical.
- **WF30 — File Fetcher**
  - скачивание файлов Telegram, дедуп по sha256.
- **WF31 — Link Fetcher**
  - скачивание страниц, дедуп.
- **WF40 — Content Extractor**
  - извлечение текста из файлов/страниц.
- **WF41 — Chunk & Embed**
  - чанкинг + эмбеддинги + запись в pgvector.
- **WF50 — Query Orchestrator (Answer with citations)**
  - принимает вопрос, делает retrieval, генерирует ответ, возвращает в Telegram.

### Администрирование и поддержка
- **WF60 — Admin Panel (Telegram commands)**
  - allowlist, chat policies, статус очередей, переиндексация.
- **WF90 — Reindex/Reprocess**
  - массовая переобработка по фильтрам (чат/период/модель эмбеддинга).
- **WF99 — Global ERR Handler**
  - единый обработчик ошибок Postgres/HTTP/Telegram с ErrorEnvelope + correlation.

## 9) Ошибки, корреляция, идемпотентность
- Каждое событие/задача несёт **correlation_id**.
- Все Postgres nodes: On Error → error output → WF99.
- Все критичные записи — **upsert** по естественным ключам.
- Повторная обработка безопасна (at-least-once delivery).

## 10) Масштабирование
- Разнести ingest и тяжелую обработку (extract/embed) по очереди ops_jobs.
- Split in Batches + лимиты параллельности.
- Индексы:
  - btree по (chat_id, message_id), timestamps;
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
1) Слои данных: RAW → Canonical → Knowledge → Facts → Audit.
2) ACL применяется **до** генерации ответов.
3) Все Postgres nodes обрабатывают ошибки через error output и общий ERR handler.
4) Минимизировать Code node, по максимуму собирать логику стандартными нодами.

