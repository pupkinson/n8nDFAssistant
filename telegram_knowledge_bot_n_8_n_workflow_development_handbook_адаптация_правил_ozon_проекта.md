# Telegram Knowledge Bot — n8n Workflow Development Handbook

> Адаптация правил разработки workflow из проекта «Ozon: n8n + PostgreSQL» под проект «Telegram Knowledge Bot».  
> Цель: единые, воспроизводимые правила, чтобы workflow импортировались без ручных правок, были надёжными, наблюдаемыми, масштабируемыми и безопасными.

---

## 1) Проектные инварианты

### 1.1 Запреты (жёсткие)
1) **`$env.*` запрещён** во всех workflow.
2) **Secrets запрещены в БД**. Всё хранить в **n8n Credentials**.
3) **Code node — по умолчанию 0**. Разрешён только если иначе никак, с явным WHY в Notes.
4) **Запрещено** собирать объекты через object-literal в выражениях вида `={{ { ... } }}`.
   - Все структуры — только **Set + dotNotation**.
5) **Динамическая SQL-конкатенация запрещена**.
6) **Mock-ветки, подменяющие prod-path, запрещены**.
   - Тесты делаются отдельными входами/ветками и не влияют на prod-path.

### 1.2 Приоритеты
- Надёжность и наблюдаемость **важнее** «красоты».
- Идемпотентность и дедупликация — обязательны.
- Максимум логики — в стандартных нодах n8n (Set/IF/Switch/Merge/Split in Batches), минимум кода/SQL.

### 1.3 Важные особенности Telegram
- Проект исходит из **at-least-once доставки** (webhook/updates могут повторяться) → дедуп обязателен.
- Редактирование сообщений (edited_message) трактуется как **новая версия**.

---

## 2) Стандарты оформления workflow

### 2.1 Именование
**Workflow:** `WF10 — Telegram Ingest`, `WF20 — Normalize & Persist`, `WF41 — Chunk & Embed`, `WF50 — Query Orchestrator`.

**Ноды:** `PREFIX — Action`.
Рекомендуемые префиксы:
- `IN —` вход/триггер
- `GUARD —` валидация
- `TG —` Telegram API / разбор апдейта
- `HTTP —` внешние HTTP (links, Gemini)
- `DB —` Postgres операции
- `RAW —` операции с RAW-слоем
- `CAN —` canonical слой
- `KG —` knowledge слой (chunks/embeddings)
- `ACL —` политика доступа
- `AUD —` аудит
- `CTL —` роутинг (Switch/IF)
- `ERR —` обработка ошибок
- `OUT —` сборка envelope/ответа
- `TST —` тест-харнесс

### 2.2 Notes обязательны (на каждой ноде)
В Notes каждой ноды обязательно:
1) Назначение (1–2 строки)
2) Входы (какие поля ожидаются)
3) Выходы (что гарантируется)
4) Нестандартные флаги → **WHY** + где/как обработаны последствия

---

## 3) Единый контракт ответов (Envelope)

### 3.1 SuccessEnvelope (канон)
- `ok: true`, `status_code: 200`
- `data`: результат (в т.ч. `answer`, `sources`, `actions` если есть)
- `meta.correlation`: обязателен

### 3.2 ErrorEnvelope v1 (канон, **только WF99**)

В проекте действует **ErrorPipe Contract v1**: единый `ErrorEnvelope` формирует и возвращает **только WF99**.

- Рабочие workflow **не** собирают ErrorEnvelope «у себя» (особенно на I/O ошибках).
- Любая I/O ошибка (Postgres/HTTP/Telegram) обязана уходить в WF99 через Execute Workflow, после чего ветка завершается StopAndError.

**Форма ErrorEnvelope v1 (возвращает WF99):**
- `ok: false`
- `status_code: number`
- `data: null`
- `error.kind: string`
- `error.message: string`
- `error.retryable: boolean`
- `error.details` (объект):
  - `ctx: object`
  - `raw_error: object` (например `{ message, http_code, node_type }`)
  - `error_context: object | null`
  - `test_mode/test_case` (если используется)
- `meta.source = "WF99"`
- `_internal` (служебное)

**Критично:** `error.details.*` всегда пишется/передаётся как **объект**, не строка (никаких stringify / raw-json-only).

### 3.3 ErrorPipe Contract v1 (как вызывать WF99)

На error-ветке всегда:
1) Явно штамповать источник ошибки (строками): `_err.node/_err.operation/_err.table`.
2) На error output нельзя рассчитывать, что контекст сохранился → **приклеить `_ctx`** Set-нодой (`includeOtherFields=true`).
3) Подготовить `error_context.*` и обеспечить `ctx = _ctx`.
4) Вызвать WF99 (Execute Workflow):
   - предпочтительно `passThrough`;
   - если `defineBelow` — запрещён пустой `{}`; обязательно маппить `ctx`, `error_context` и поля error output.
5) После WF99 — StopAndError.

В `ctx` всегда поддерживать `ctx.contracts.errorpipe = 1`.

### 3.4 Retry policy
- 429, временные 5xx, timeout → `retryable: true` + backoff
- 401/403, validation, not_found → `retryable: false`

---

## 4) Сборка структур: только Set + dotNotation

### 4.1 Правило
Любые объекты (**ctx/meta/error/details/defaults/sources**) строятся **поле-за-полем** через Set с `dotNotation`.

### 4.2 Канонические блоки (рекомендуемые ноды)
- `OUT — SuccessEnvelope (dot)`
- `OUT — ErrorEnvelope (dot)`
- `ACL — Build AccessScope (dot)`
- `CAN — Default entity (dot)`

---

## 5) Postgres node — строгая политика

### 5.1 Разрешённые операции (по умолчанию)
Только: `select / insert / update / upsert / delete`.

### 5.2 Execute Query (SQL)
- **Запрещён по умолчанию**.
- Разрешён только если без него невозможно (например, сложный retrieval по pgvector/fts), при условиях:
  1) оформлен ADR (WHY)
  2) запрос параметризован (без конкатенации)
  3) есть тесты
- Предпочтение: вынести сложную логику в **DB view / DB function** и дергать её стандартным select.

### 5.3 Always Output Data (AOD)
- Default: **OFF**.
- **ON** только для optional lookup, где 0 rows — ожидаемый кейс.
- Если AOD=ON → обязательна явная обработка «пустого результата».

### 5.4 Required vs Optional lookup
- **Required:** 0 rows → бизнес-ошибка (404/403), НЕ «пустой item».
- **Optional:** 0 rows → дефолт через ноды.

### 5.5 Дефолт без SQL (канон)
**Default item + Merge**:
1) `DB — Select ...` (AOD=OFF)
2) `CTL — IF rows==0` → `SET — Default (dot)` (создать 1 item)
3) `MERGE — Choose actual/default` (в результате всегда 1 item)

### 5.6 Обработка ошибок Postgres (обязательно, ErrorPipe v1)

**Единственный стандарт для I/O ошибок (DB):**

1) На каждой Postgres ноде: **On Error: Continue using error output**.
2) Error output → `ERR — Source <Exact NodeName>` (Set/Edit Fields)
   - `includeOtherFields=true` (не теряем `message/error/description/n8nDetails`)
   - задать строками:
     - `_err.node = "<Exact NodeName>"`
     - `_err.operation = "select|insert|update|delete|upsert"`
     - `_err.table = "schema.table"`
   - приклеить `_ctx` (взять из ранней точки контекста).
3) `ERR — Prepare DB Error (v1)` (Set + dotNotation)
   - `ctx = _ctx`
   - `ctx.contracts.errorpipe = 1`
   - `error_context.node/operation/table/error_message/status_code/correlation_id`
   - **не резать item целиком** (никаких raw-json-only).
4) `ERR — Call WF99` (Execute Workflow) → **StopAndError**.

**Запрет:** продолжать success-ветку после I/O ошибки.

Классификация retryable (DB):
- retryable=true: timeout/connection reset/deadlock/serialization failure/temporary unavailable
- retryable=false: constraint violation/undefined column/table/invalid input syntax

---

## 6) HTTP (Telegram, Gemini, Web) — строгая политика

### 6.1 Ошибки HTTP/Telegram/Gemini: error output → WF99 (ErrorPipe v1)

Любая HTTP/Telegram/Gemini нода:
1) On Error → **Continue using error output**.
2) Error output → `ERR — Source <Exact NodeName>` (includeOtherFields=true) + приклейка `_ctx`.
3) `ERR — Prepare Upstream Error (v1)`:
   - `ctx = _ctx` + `ctx.contracts.errorpipe = 1`
   - `error_context.node/operation/table` (для HTTP table можно оставить null, operation = "http")
   - `status_code` берём из `statusCode/httpCode` если есть, иначе 500
4) Execute Workflow → **WF99** → StopAndError.

### 6.2 Коды (канон)
- 429 → `rate_limit`, retryable=true
- 5xx → `upstream`, retryable=true
- 401/403 → `auth`, retryable=false
- 404 → `not_found`, retryable=false
- 4xx прочие → `input_validation` или `upstream` (по смыслу), retryable=false

### 6.3 Rate limiting/backoff
- Импортёр обязан учитывать лимиты:
  - Telegram API (общие лимиты + специфичные методы)
  - внешние сайты при fetch ссылок
  - Gemini API
- Backoff: экспонента + джиттер (реализовать нодами Wait/IF + счётчик попыток).

### 6.4 Корреляция
- В каждый HTTP запрос — прокидывать `correlation.trace_id` (в заголовок/метаданные workflow) и писать в audit.

---

## 7) Идемпотентность и дедупликация

### 7.1 Общие правила
- Повторный прогон не должен плодить дубли.
- В БД должны быть UNIQUE-ограничения под идемпотентность.

### 7.2 RAW слой (Telegram updates)
- RAW пишется **до** canonical/knowledge.
- Дедуп по `update_id` и/или по `(chat_id, message_id, sent_at)` + hash.
- Версии `edited_message` сохранять как отдельные версии (message_version).

### 7.3 Файлы и ссылки
- Файлы: дедуп по `sha256` (и/или tg `file_unique_id`).
- Ссылки: дедуп по `normalized_url` + `sha256_content`.

---

## 8) Наблюдаемость

### 8.1 audit_log
Писать для каждого значимого шага:
- параметры (chat_id, message_id, user_id, job_type)
- результаты (counts, duration)
- ошибки (kind/message/details)

### 8.2 `ops.jobs` / job queue
- Любая тяжелая работа (fetch/extract/embed) идёт через очередь задач.
- Поля: `status`, `attempts`, `next_retry_at`, `last_error`.

### 8.3 Запрет «тихих» фейлов
- Если I/O упал — workflow обязан завершаться ErrorEnvelope и фиксировать ошибку в `ops.errors`/audit.

---

## 9) Платформенные workflow (обязательные)

### 9.1 WF10 — Telegram Ingest
- Принимает webhook update.
- Пишет RAW.
- Создаёт ops_jobs на нормализацию/обогащение.

### 9.2 WF20 — Normalize & Persist
- Upsert users/chats/messages/memberships.
- Выделяет вложения/ссылки.
- Планирует jobs на fetch/extract/embed.

### 9.3 WF99 — Global ERR Handler (ErrorPipe Contract v1)
- WF99 — **единственная точка**, которая нормализует ошибки и возвращает канонический ErrorEnvelope v1.
- WF99 **всегда** пытается записать ошибку в `ops.errors`.
- Job-path выполняется **только если** `ctx.job_id` задан:
  - update `ops.jobs`
  - insert `ops.job_runs`
- `correlation_id`:
  - если пришёл в `ctx.correlation_id` или `error_context.correlation_id` → использовать его;
  - генерировать новый UUID только если его нет.
- Если запись в `ops.errors` не удалась — WF99 не должен падать; помечает `_internal.persist_failed=true`.
- Рабочим workflow запрещено собирать ErrorEnvelope на I/O ошибках — только через вызов WF99.

---

## 10) Тест-харнесс (внутри workflow)
---

## 10) Тест-харнесс (внутри workflow)
Минимум 3 теста:
1) happy
2) validation fail
3) upstream/db fail

Правила:
- тест-ветка/вход не влияет на prod-path
- asserts явные (IF + StopAndError)
- тесты используют отдельный Manual Trigger

---

## 11) Вывод артефактов (workflow JSON)
Основной режим:
- создавать файл `/mnt/data/<WFxx__Name__n8n-2.4.8>.json` и возвращать только ссылку.

Fallback (только если файл создать не удалось):
- вывести JSON одним блоком ` ```json ... ``` `.
- перед блоком обязательна строка: `Fallback: file creation failed`.

---

## 12) ADR registry (обязательное)
Если правило нарушается или вводится системное решение — фиксировать ADR:
- ADR-001: стратегия дедуп RAW updates
- ADR-002: политика версий edited_message
- ADR-003: стратегия хранения файлов (S3/FS) и ссылки
- ADR-004: retrieval по pgvector + full-text (hybrid)
- ADR-005: retry/backoff лимиты Telegram/Gemini/Web
- ADR-006: политика приватности/retention и удаления данных

