# Canvas Updates — ErrorPipe Contract v1

> Цель: устранить повторяемые классы ошибок из-за несогласованного формата данных между workflow, потери ctx на error-ветках и «магических» сборок ErrorEnvelope.

---

## 1) WF99 — Global ERR Handler

### 1.1. Роль WF99
WF99 — единственная точка, которая:
- нормализует входные ошибки (из любых workflow);
- записывает ошибку в `ops.errors` **всегда**;
- при наличии `ctx.job_id` дополнительно обновляет `ops.jobs` и пишет `ops.job_runs`;
- возвращает единый `ErrorEnvelope` вызывающему workflow.

### 1.2. Контракт входа (ErrorPipe Contract v1)
WF99 обязан корректно работать, если на вход приходит **любой** из следующих вариантов:

**Обязательные для корректной корреляции (желательно, но не всегда присутствует):**
- `ctx` (object) — основной контекст.
  - `ctx.correlation_id` (uuid) — сквозной идентификатор корреляции (может отсутствовать; тогда WF99 генерирует).
  - `ctx.job_id` (number) — id задания из `ops.jobs` (может отсутствовать, если ошибка произошла до создания job).

**Рекомендуемый блок (если ошибка нормализована вызывающим workflow):**
- `error_context` (object)
  - `node` (string) — **точное имя** ноды-источника ошибки (назначается в вызывающем WF на error-ветке).
  - `operation` (string) — select/insert/update/delete/upsert.
  - `table` (string) — `schema.table`.
  - `correlation_id` (uuid) — дублирование для удобства.
  - `error_message` (string).
  - `status_code` (number).

**Опционально (как есть от n8n error output / upstream):**
- `message` (string)
- `error` (object)
- `description` (string)
- `n8nDetails` (object)
- любые иные поля (WF99 не должен ломаться).

### 1.3. Инварианты WF99
1) **`ops.errors` пишется всегда** (даже если `ctx.job_id` отсутствует).
2) **Job-path выполняется только если `ctx.job_id` задан**:
   - если `ctx.job_id == null/undefined/empty` → никаких select/update/insert в `ops.jobs/ops.job_runs`.
3) **correlation_id**:
   - если на входе есть `error_context.correlation_id` или `ctx.correlation_id` → использовать его;
   - иначе → сгенерировать новый UUID.
   - генерировать «всегда» запрещено.
4) **ErrorEnvelope строится только nocode**:
   - запрещены `raw jsonOutput` сборки, которые превращают объекты в строки;
   - запрещены `JSON.stringify(...)` в местах, где ожидается json/jsonb;
   - запрещены object-literal в выражениях (`={{ {a:1} }}`), сборка только через Set+dotNotation.

### 1.4. Контракт выхода (ErrorEnvelope v1)
WF99 возвращает объект:
- `ok: false`
- `status_code: number`
- `data: null`
- `error`:
  - `kind: string`
  - `message: string`
  - `retryable: boolean`
  - `details`:
    - `ctx: object`
    - `raw_error: { message, http_code, node_type }`
    - `error_context: object | null`
    - `test_mode, test_case` (если используется)
- `meta`:
  - `source: "WF99"`
  - `correlation: { correlation_id, trace_id, workflow, node }`
  - `ts: ISO string`
- `_internal`:
  - `correlation_id`
  - `tenant_id`
  - `job_id`
  - `test_mode, test_case, _test_job_id` (если используется)

### 1.5. Fixtures (контрольные примеры)
**Fixture A — ошибка после создания job:**
```json
{
  "ctx": {"correlation_id":"<uuid>","job_id":123,"workflow":"WF10"},
  "error_context": {"node":"Lookup Bot","operation":"select","table":"core.bots","correlation_id":"<uuid>","error_message":"...","status_code":500},
  "message":"..."
}
```
Ожидание:
- `meta.correlation.correlation_id == <uuid>`
- `error.details.error_context.node == "Lookup Bot"`
- `ops.errors` записан
- job-path выполнен (job_id есть)

**Fixture B — ошибка до создания job:**
```json
{
  "ctx": {"correlation_id":"<uuid>","workflow":"WF10"},
  "error_context": {"node":"Insert Updates","operation":"insert","table":"raw.telegram_updates","correlation_id":"<uuid>","error_message":"...","status_code":500},
  "message":"..."
}
```
Ожидание:
- `ops.errors` записан
- job-path **не** выполняется
- нет `undefined` в envelope

### 1.6. Версионирование контракта
Чтобы избежать «тихого» дрейфа формата:
- добавить в контекст: `ctx.contracts.errorpipe = 1` (или эквивалент);
- WF99 может логировать/сохранять эту версию в `ops.errors.details`.

---

## 2) WF10 — Telegram Webhook Receiver (Update → Job)

### 2.1. Роль WF10
WF10 принимает update, нормализует контекст, пишет update в БД и создаёт job.
Критично: WF10 является источником правды для `error_context` при DB-ошибках на своих Postgres-нодах.

### 2.2. Инварианты контекста
1) `_ctx` (и/или `ctx`) должен формироваться **максимально рано** (до DB-операций).
2) `correlation_id` создаётся один раз и далее передаётся везде:
   - нормальный путь;
   - error path (error output) — через явное «приклеивание» ctx.

### 2.3. Обработка DB ошибок (обязательная схема)
Для каждой Postgres-ноды, которая может упасть и ведёт в WF99:

**Postgres Node (error output)** → **Set “ERR — Source <NodeName>”** → **Prepare DB Error** → **Call WF99**

Где:
- “ERR — Source …”:
  - добавляет `_err.node/_err.operation/_err.table` (строками);
  - копирует `_ctx` из ноды-источника контекста;
  - `includeOtherFields=true`, чтобы не потерять `message/error/description`.

- “Prepare DB Error”:
  - **не режет item** (не raw-json-only);
  - создаёт `error_context.*` и копирует `ctx = _ctx`.

### 2.4. Вызов WF99
- “Call WF99” обязан передавать фактический payload.
- Предпочтительно: passThrough.
- Если defineBelow: обязательно маппить `ctx` и `error_context` + поля error output.

---

## 3) Project Rules — Error Handling & Context Propagation (n8n Style)

### 3.1. Запрещённые практики (источник прошлых ошибок)
1) Пытаться получать имя upstream-ноды автоматически в expressions.
2) Собирать объекты через `raw jsonOutput`, который затирает item целиком.
3) Использовать `JSON.stringify(...)` для полей, которые должны остаться объектами (json/jsonb).
4) Использовать object-literal в выражениях.

### 3.2. Обязательные практики
1) **Источник ошибки штампуется явно**:
   - на error-ветке задаём `_err.node/_err.operation/_err.table`.
2) **Контекст на error output не гарантирован**:
   - всегда “приклеивать” `_ctx` на error-ветке Set-нодой.
3) **ErrorEnvelope — строго nocode**:
   - Set/Edit Fields + dotNotation.
4) **Gating job-path**:
   - любые действия с `ops.jobs/ops.job_runs` только если `ctx.job_id` задан.

### 3.3. Минимальный чек-лист перед merge
- Любая DB-ошибка приводит к записи в `ops.errors`.
- correlation_id не теряется на error-ветках.
- В envelope нет `undefined`.
- `error.details` — объект, а не строка.
- job-path не выполняется, если job_id отсутствует.

---

## 4) Нотации/термины
- `correlation_id` (uuid) — сквозная корреляция логов/ошибок.
- `job_id` (number) — `ops.jobs.id` (bigserial).
- `error_context` — прикладной контекст ошибки (какая нода/операция/таблица).



---

## 5) Audit for other canvases in the project

> Этот раздел предназначен для синхронизации остальных canvas/документов проекта, чтобы они не конфликтовали с ErrorPipe Contract v1.

### 5.1. Что обязательно должно совпадать везде
- **ctx vs _ctx**: внутри межворкфлоу-контрактов используется `ctx` как каноническое имя. `_ctx` допустим как внутренний технический контейнер внутри одного WF, но при вызове других WF (включая WF99) должен быть доступен `ctx`.
- **correlation_id**: `ctx.correlation_id` — UUID, используется для сквозной корреляции (логи/ошибки/трейс). Это **не** `job_id`.
- **job_id**: `ctx.job_id` — числовой `ops.jobs.id` (bigserial). Может отсутствовать до создания job — это нормальный сценарий.
- **error_context**: прикладной контекст ошибки (node/operation/table/message/status). Имя ноды берётся только из `error_context.node`, и оно задаётся явно в вызывающем WF.
- **ErrorEnvelope**: сборка строго nocode (Set/Edit Fields + dotNotation), без stringify и без raw-json-only, чтобы json/jsonb оставались объектами.

### 5.2. Правила вызова сабворкфлоу (Execute Workflow)
Во всех canvas, где описывается вызов WF99 (или любых shared WF):
- Запрещён пустой mapping (`{}`) при `defineBelow`.
- Предпочтительно `passThrough`.
- Если используется `defineBelow`, обязательно маппить `ctx` и основные блоки (`error_context`, `req`, `meta` — по контракту конкретного WF).

### 5.3. Error output и сохранение контекста
Во всех canvas, где описывается работа с Postgres/HTTP:
- Любая нода с риском ошибки должна вести error output в общий обработчик.
- На error-ветке нельзя рассчитывать, что `ctx/_ctx` сохранился — его нужно «приклеивать» Set-нодой (includeOtherFields=true).
- `Prepare ... Error`-ноды не должны уничтожать item целиком.

### 5.4. JSONB/объекты в БД
В документах по ops-таблицам (и в примерах):
- `ops.errors.details` и `ops.job_runs.error` пишутся как **объекты**, не строки.
- Любое `JSON.stringify(...)` в логике формирования деталей ошибки — запрещено.

### 5.5. Быстрый чек-лист поиска конфликтов в существующих canvas
Если в любом canvas встречается что-то из ниже перечисленного — документ нужно обновить:
- утверждение/намёк, что `_ctx.correlation_id` = `ctx.job_id` или что одно заменяет другое;
- что WF99 всегда генерирует correlation_id, игнорируя входной;
- что `ops.errors` пишется только при наличии job_id;
- примеры сборки ErrorEnvelope через raw-json-only или через stringify;
- описание вызова WF99 с `defineBelow` и пустым `{}`.

### 5.6. Рекомендуемая вставка в canvas про контекст (WF00c/ctx)
Добавить в раздел контекста:
- `ctx.correlation_id` (uuid) — сквозная корреляция.
- `ctx.job_id` (number) — привязка к ops.jobs (опционально).
- При вызове shared WF всегда передавать `ctx` (не только `_ctx`).

