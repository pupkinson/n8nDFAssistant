# Telegram Knowledge Bot — Жёсткие правила разработки n8n workflow (v2)

Эти правила обязательны для всех промптов генерации workflow и для всей реализации проекта.

**Источник истины проекта:**

- **DB схема:** `SQL.txt`
- **Credentials / версии нод:** `Credentials.json`
- **Справочник по нодам n8n:** 2×MCP (см. canvas «Telegram Knowledge Bot — единый регламент проекта (n8n 2.4.8) + 2×MCP»)
  - MCP#1: `n8n-mcp` (параметры/версии нод, справочник)
  - MCP#2: второй MCP сервера проекта (имя и правила использования — в «едином регламенте»)

---

## 1) Безопасность и секреты

1. **Secrets НЕ хранить в БД.** Всё — только в **n8n Credentials**.
2. Исключения (если и появятся) фиксируются отдельным решением и документируются.
3. **\$env.\***\*\* в workflow запрещён\*\* (в любых выражениях и полях).

---

## 2) Nocode-first

1. **Минимум Code node.** Логика — через стандартные ноды (Set/IF/Switch/Merge/Date&Time/Crypto/Postgres/HTTP/Telegram).
2. Если Code node неизбежен (редко):
   - коротко, детерминированно,
   - без сетевых вызовов,
   - с комментариями,
   - с объяснением WHY в Notes.
3. Для отдельных workflow может действовать более жёсткое правило: **Code node = 0**.

---

## 3) Notes у каждой ноды

Для **каждой** ноды обязательны Notes:

- что делает нода,
- какой вход ожидает и какой выход формирует,
- WHY — если включён нестандартный флаг/опция.

---

## 4) Контракт → тесты → реализация

1. Сначала фиксируется **контракт входа/выхода** (см. canvas: «Контракты входа/выхода workflow»).
2. Затем делаются тесты (минимум 3):
   - happy,
   - edge,
   - fail.
3. Потом реализация.

### Тесты должны быть “по-настоящему”

- **Тесты обязаны писать в БД** и проверять результаты через SELECT.
- **Тесты обязаны делать cleanup** (DELETE своих записей), чтобы не захламлять прод-таблицы.
- Ассерты не должны искать «последнюю запись по времени» — только по ключам теста (например, `correlation_id`, `job_id`).

### Запрет mock-веток

- Запрещены ветки, которые **подменяют prod-path** данных.
- Тестовая ветка может формировать тестовый вход, но дальше должна прогонять **тот же core pipeline**, что и прод.

---

## 5) Postgres node policy: никаких SQL-«хаков»

### Разрешённые операции

- По умолчанию разрешены только: **select / insert / update / upsert / delete**.
- **Execute Query / произвольный SQL запрещён**, если задачу можно решить стандартными операциями.

### Запреты

- Запрещены любые SQL-строки с динамической подстановкой/конкатенацией.

### Always Output Data

- По умолчанию **OFF**.
- **ON** допустим только для optional lookup, где отсутствие строки ожидаемо, и дальше стоит явная обработка пустого результата (Guard + Default через Set/Merge).
- Для required lookup: **AOD=OFF**, 0 rows → бизнес-ошибка (404/403), а не «пустой item».

### Паттерн “гарантировать 1 item”

Если select может вернуть 0 строк, а дальше нужен item:

- `SET — Default item` → `MERGE — merge with select result`.

---

## 6) STRICT обработка ошибок I/O (Postgres/HTTP/Telegram)

Цель: любая I/O ошибка даёт управляемый ErrorEnvelope, **всегда** логируется через `ops.errors` и не ведёт к «частичным успехам». Формат и поведение строго соответствуют **ErrorPipe Contract v1**.

### 6.1 Инварианты ErrorPipe Contract v1

1. **WF99 — единственная точка нормализации ошибок и сборки ErrorEnvelope.** Рабочим workflow запрещено «изобретать» свои форматы ErrorEnvelope.
2. На error-ветках нельзя рассчитывать, что контекст сохранился — его нужно **явно приклеивать**.
3. `correlation_id`:
   - если на входе уже есть `ctx.correlation_id` или `error_context.correlation_id` — использовать **его**;
   - генерировать новый UUID только если его нет.
4. **ErrorEnvelope и error.details пишутся как объекты (json/jsonb), не строки.**
   - запрещены `JSON.stringify(...)` там, где ожидаются объекты;
   - запрещены `raw jsonOutput`, который затирает item целиком;
   - запрещены object-literal в выражениях (`={{ {a:1} }}`) — сборка объектов только через Set + dotNotation.
5. Job-path (ops.jobs/ops.job\_runs) выполняется **только если **``** задан**.

### 6.2 PATTERN A (по умолчанию) — ErrorPipe через WF99

Для каждой I/O ноды (Postgres/HTTP/Telegram):

1. На I/O ноде включить **Continue using error output**.
2. Error output → **Set: **``
   - `includeOtherFields=true` (чтобы не потерять `message/error/description/n8nDetails`)
   - записать строками:
     - `_err.node = "<Exact NodeName>"` (точное имя ноды)
     - `_err.operation = "select|insert|update|delete|upsert"` (для Postgres)
     - `_err.table = "schema.table"` (для Postgres)
   - приклеить `_ctx` (или `ctx`) из ранней точки контекста (см. раздел про контракты).
3. **Set: **`` (nocode, dotNotation)
   - `ctx = _ctx` (каноническое имя для меж-WF контрактов)
   - `ctx.contracts.errorpipe = 1`
   - `error_context.node = _err.node`
   - `error_context.operation = _err.operation`
   - `error_context.table = _err.table`
   - `error_context.correlation_id = ctx.correlation_id`
   - `error_context.error_message` = взять из `message`/`errorMessage`/`description` (что есть)
   - `error_context.status_code` = если есть `statusCode/httpCode`, иначе 500
   - не «резать» item: сохранять исходные поля ошибки (message/error/description/n8nDetails).
4. **Execute Workflow: WF99 — Global ERR Handler**
   - предпочтительно `passThrough`.
   - если используется `defineBelow`, запрещён пустой `{}`; обязательно маппить `ctx` и `error_context` и поля ошибки.
5. После вызова WF99 — **StopAndError** (успешный путь после ошибки запрещён).

### 6.3 Исключение (только внутри WF99)

- WF99 обязан **пытаться писать в **``** всегда**; если запись не удалась, WF99 не должен падать, но обязан отметить `persist_failed=true` в details.

### 6.4 Retry On Fail

- Включать только на I/O нодах и только если есть понятная стратегия (кол-во попыток/задержка) и WHY в Notes.
- Retry не отменяет ErrorPipe: после исчерпания попыток ошибка всё равно уходит в WF99.

### 6.5 Минимальная классификация

- `kind`: `db | upstream | auth | rate_limit | unknown`
- `retryable=true` только для временных проблем (timeout/connection reset/deadlock/serialization/temporary unavailable/429).

---

## 7) Merge node policy (Hard Rule)

### Инвариант

В n8n JSON у ноды **Merge** количество входов **не выводится автоматически** из связей.

Если у Merge больше 2 входов, **обязательно** явно выставлять:

```json
"parameters": {
  "numberInputs": 3
}
```

где `3` — фактическое число входящих соединений.

### Запрещено

- Оставлять `numberInputs` по умолчанию (=2), если входов 3+.
- Подключать 3+ входящих связей к Merge без увеличения `numberInputs`.

### Обязательная самопроверка перед финальным JSON

Для каждой ноды типа `n8n-nodes-base.merge`:

1. Посчитать количество входящих соединений (in-degree).
2. Проверить, что `parameters.numberInputs` существует и равен этому числу.
3. Если не совпадает — исправить и только потом финализировать JSON.

### Notes для Merge

- Зачем Merge.
- Сколько входов ожидается (N).
- Что приходит на каждый вход.

### Требование для промптов генерации workflow

В каждый промпт генерации workflow ОБЯЗАТЕЛЬНО включать правило:

- «Если в workflow есть Merge с 3+ входами — выставь `parameters.numberInputs = N`, где N = число входящих связей. Иначе JSON считается неверным и должен быть исправлен до выдачи.»

Также в промпте обязателен пункт **IMPORT SAFETY CHECK**:

- перед финальным выводом JSON выполнить самопроверку: ни одна Merge-нода не имеет больше входящих связей, чем указано в `numberInputs`.

---

## 8) Quality gates для генерации JSON

Перед выдачей workflow JSON обязательно проверить:

1. Все credentials names строго из `Credentials.json`.
2. Нет `$env.*`.
3. Каждая I/O нода (Postgres/HTTP/Telegram) имеет error-output handling и **ErrorPipe v1**:
   - `_ctx/ctx` сформирован до I/O,
   - на error-ветке есть `ERR — Source <NodeName>` (includeOtherFields=true) + `ERR — Prepare ErrorPipe v1`,
   - вызов WF99 сделан с passThrough (или корректным defineBelow), затем StopAndError.
4. Ни в одном workflow (кроме WF99) нет «самодельного» ErrorEnvelope.
5. Не используются запрещённые практики:
   - `raw jsonOutput`/«резать item целиком»,
   - `JSON.stringify(...)` для json/jsonb,
   - object-literal в выражениях.
6. Merge ноды: `numberInputs` соответствует входящим связям.
7. Нет Execute Query (если это не отдельное явно разрешённое исключение, зафиксированное решением).
8. Есть тестовая ветка (Manual Trigger) с записью в БД + verify + cleanup.
9. Любой workflow, который используется как sub-workflow, документирует вход/выход в canvas «Контракты входа/выхода workflow» и использует канонические имена (`ctx`, `error_context`, `req`).

## 9) Связанные документы

- Контракты I/O между workflow: **«Telegram Knowledge Bot — Контракты входа/выхода workflow»**

> Примечание: отдельный документ **«Telegram Knowledge Bot — Merge Node Policy (Hard Rule)»** считается полностью объединённым в этот регламент и больше не является источником истины.

