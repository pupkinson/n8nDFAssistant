---
name: Workflow (n8n)
about: Implement or modify an n8n workflow JSON in /workflows
title: "[WF] "
labels: ["tracked","type:feature"]
---

## Workflow ID / File
- Target file: `workflows/WFxx — <name>.json`
- Related workflows: (WF00c/WF90/WF99/etc.)

## Goal
(что должно заработать)

## Inputs (contract)
- Trigger:
- Required fields:
- Correlation fields:

## Outputs (contract)
- SuccessEnvelope:
- ErrorEnvelope:
- Side effects (DB writes/jobs):

## DB Touchpoints (SQL.txt only)
- Tables:
- Operations (select/insert/update/upsert/delete only):

## Error handling (MANDATORY)
- [ ] Postgres/HTTP nodes use error output
- [ ] errors routed to WF99 / ErrorPipe
- [ ] correlation preserved

## Idempotency / Dedup
- Dedup key(s):
- Retry behavior:

## Acceptance Criteria
- [ ] JSON imports in n8n without manual edits
- [ ] CI validators green
- [ ] Happy path tested (steps + evidence)
- [ ] Failure path tested (steps + evidence)
- [ ] Notes updated on all changed nodes

## Test Evidence
- Screenshots / run logs links:
