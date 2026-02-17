# Agent Operating System (DF Assistant Bot)

This file is the operational contract for Codex, Claude Code, and Gemini CLI.

## Roles
- Architect: Codex
  - plans task shape, constraints, and acceptance checks
- Implementer: Claude Code
  - edits files, runs validators, updates PR
- Researcher: Gemini CLI
  - produces short evidence-backed research notes and change options
- Reviewer: Codex
  - reviews diffs for regressions, policy violations, and missing tests

## Required workflow loop
1. Pick issue from Project column `Ready`.
2. Create branch from `main` using one of:
- `feat/issue-short`
- `fix/issue-short`
- `chore/issue-short`
3. Implement smallest safe change set.
4. Run local validation:
- `node scripts/validate-workflows.mjs`
5. Open PR using `.github/pull_request_template.md`.
6. Resolve CI failures before requesting review.
7. Update issue status and link PR.

## Commit convention
- Format: `<type>(<scope>): <summary>`
- Examples:
- `feat(wf50): enforce acl guard for group retrieval`
- `fix(ci): require needs-human on acl workflow changes`
- `chore(docs): tighten escalation triggers`

## CI signal interpretation
- `ci / validate` failed at `ci-guard-needs-human.sh`:
  - critical files changed without `needs-human`; stop and escalate.
- `ci / validate` failed at `validate-workflows.mjs`:
  - fix workflow/script violations (env usage, executeQuery policy, JSON issues), rerun locally, push.
- all checks green:
  - continue normal review/merge flow.

## needs-human handling
- If `needs-human` is required, agents stop blocked scope.
- Open/complete escalation issue template and capture options/risks.
- Wait for human decision before continuing blocked changes.

## Branch protection rule
- No direct pushes to `main`.
- Enforcement is via GitHub branch protection; agents must always use PRs.

## Hard constraints (summary)
- `SQL.txt` and `Credentials.json` are source of truth.
- No secrets in repo.
- No `$env.*`.
- Postgres errors must route to `WF99` via error output.
- `executeQuery` is forbidden except `DB RO` read-only policy.
- Group ACL is chat-scoped; admin super-scope allowed only in DM.
