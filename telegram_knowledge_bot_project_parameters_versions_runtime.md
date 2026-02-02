# Telegram Knowledge Bot — Project Parameters (Versions & Runtime)

## Current runtime baseline
- **n8n version:** **2.4.8** (self-hosted)
- **Database:** PostgreSQL + pgvector
- **Bot platform:** Telegram Bot API
- **LLM/Embeddings:** Google Gemini API

## Canonical rule
All project artifacts (architecture docs, handbooks, prompts, workflow JSON generation requirements) must assume **n8n 2.4.8**.

If any earlier artifact mentions a different n8n version (e.g., 2.3.x / 2.3.1), treat it as **legacy wording** and replace with **2.4.8** when generating:
- workflow JSON
- file naming
- tests
- notes/metadata

## Workflow artifact naming
- JSON export filenames must use suffix: `__n8n-2.4.8.json`
  - Example: `WF99__Global_ERR_Handler__n8n-2.4.8.json`

## Engineering constraints (unchanged)
- `$env.*` forbidden everywhere.
- Secrets only in n8n Credentials.
- Prefer nocode (Set dotNotation, IF/Switch, Merge). Code node minimized.
- All Postgres nodes: **On Error: Continue using error output** → global ERR handler pattern.

---
This document is the single source of truth for versioning.

