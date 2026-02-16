# Gemini Assistant Context: DF Assistant Bot

This document provides a comprehensive overview of the "DF Assistant Bot" project for the Gemini assistant. It outlines the project's purpose, architecture, and development conventions to ensure effective and consistent collaboration.

## 1. Project Overview

**DF Assistant Bot** is a sophisticated Telegram knowledge bot designed to automatically build a knowledge base from corporate Telegram chats. It leverages **n8n.io** for workflow orchestration, **PostgreSQL with pgvector** for data persistence and semantic search, and **Google Gemini** for AI-powered answering and content embedding.

### Core Capabilities:
- **Automatic Knowledge Ingestion:** Captures and processes messages, files, links, and media from designated Telegram groups and direct messages.
- **Cited Answers (RAG):** Provides users with answers grounded in the collected knowledge, complete with citations and links to the original source messages.
- **Access Control (ACL):** Enforces strict privacy and access rules, ensuring users can only query information from chats they are members of.
- **Resilient & Scalable:** The architecture is designed for robustness with detailed error handling and a job-based system for handling intensive tasks.

## 2. Architecture

The system is built as a series of interconnected **n8n workflows** that form a data processing pipeline. The source of truth for the database schema is `SQL.txt`, and for workflow I/O contracts is `telegram_knowledge_bot_контракты_входа_выхода_workflow.md`.

### High-Level Workflow:
1.  **Ingest (WF10):** A Telegram webhook receives updates, saves the raw data to the `raw.telegram_updates` table, and enqueues a `normalize_update` job in `ops.jobs`.
2.  **Normalize (WF20):** This worker processes the raw update, normalizes Telegram entities (users, messages, chats) into the `tg.*` schema tables, and creates further jobs for content analysis (e.g., `fetch_tg_file`, `fetch_url`).
3.  **Enrichment & Extraction (WF30-WF42):** A suite of specialized workflows handles:
    - `WF30`/`WF31`: Fetching files and links.
    - `WF34`/`WF35`: Full and partial (probe) Speech-to-Text for voice messages.
    - `WF42`: Describing images and videos using VLM.
    - `WF40`: Extracting text content from documents (PDF, DOCX, etc.).
4.  **Knowledge Building (WF41):** Extracted text is segmented into chunks, converted into vector embeddings using a Google Gemini model, and stored in the `kg.chunk_embeddings_1536` table.
5.  **Query & Answering (WF50, WF51):**
    - **WF50 (Orchestrator):** Handles user questions, enforces ACL rules by determining the accessible `chat_id` scope, and performs a hybrid search (semantic + keyword) to retrieve relevant chunks.
    - **WF51 (Answerer):** Uses the retrieved chunks and the user's question to generate a final answer with Gemini, formats it with citations, records the interaction in `audit.*` tables, and sends the response back to Telegram.
6.  **Error Handling (WF98, WF99):** A robust, two-tiered error handling system ensures stability. The **ErrorPipe Contract v1** mandates that all I/O errors are routed to the **WF99 Global ERR Handler** for centralized logging to `ops.errors`. **WF98** acts as a final backstop for unmanaged platform-level errors.

## 3. Development Conventions

The project adheres to a strict set of development rules documented in `telegram_knowledge_bot_жёсткие_правила_разработки_n_8_n_workflow_v_2.md`. When modifying or creating workflows, these rules are paramount.

### Key Guidelines:
- **Nocode-First:** Minimize the use of the `Code` node. Prefer standard n8n nodes for logic (Set, IF, Switch, Merge).
- **Secrets in Credentials:** All secrets (API keys, tokens) **must** be stored in n8n Credentials, not in workflows or the database. `$env.*` expressions are forbidden.
- **Strict ErrorPipe Contract v1:** Every I/O node (Postgres, HTTP, Telegram, AI) **must** have its error output connected to a sequence that prepares and calls the `WF99` global error handler. Managed errors must not lead to a `StopAndError` node directly.
- **DB Schema is King:** `SQL.txt` is the single source of truth for all database table and column names. Do not use `Execute Query` in Postgres nodes if a standard operation (select, insert, upsert) can be used.
- **Carry & Restore Pattern:** To prevent n8n from dropping data after I/O nodes, use the "Carry -> I/O -> Restore" or "Branch + Merge" pattern to preserve the context (`ctx`, `req`, etc.).
- **Mandatory Notes:** Every node in every workflow must have a clear and concise note explaining its purpose, inputs, and outputs.
- **Test-Driven:** Workflows must include a manual trigger and a test branch that writes data to the database, verifies the outcome with `SELECT`, and cleans up after itself with `DELETE` (never `deleteTable`).

## 4. Key Files & Directories

- **/workflows/**: Contains all n8n workflow JSON definitions.
- **/n8n examples/**: Contains JSON examples of specific node configurations.
- `SQL.txt`: The definitive source for the PostgreSQL database schema.
- `telegram_knowledge_bot_архитектура...md`: The primary architecture document.
- `telegram_knowledge_bot_жёсткие_правила...md`: The mandatory development rulebook.
- `telegram_knowledge_bot_контракты...md`: Defines the I/O contracts between workflows.
- `GEMINI.md`: This file.
