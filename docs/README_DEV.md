# Developer README (Agent Loop)

## Prerequisites
- Git
- Node.js 20
- GitHub CLI (`gh`)

## 1) Create work item
- Create issue from template in GitHub UI:
  - `Task`
  - `Bug`
  - `Escalation` (blocked only)
- Put issue in Project column `Ready`.

## 2) Start branch
- `git checkout main`
- `git pull`
- `git checkout -b feat/issue-short` (or `fix/...`, `chore/...`)

## 3) Implement + validate
- Make minimal safe changes.
- Run:
- `node scripts/validate-workflows.mjs`

## 4) Open PR
- `gh pr create --fill`
- Complete `.github/pull_request_template.md`.
- Link issue with `Refs #<id>` or `Fixes #<id>`.

## 5) Labels and guards
- Auto-label workflows add:
  - `db-change` for `SQL.txt`
  - `critical-credentials` for `Credentials.json`
  - `acl-change` for `WF00c/WF50/WF51`
- CI guard fails PR if critical files changed and `needs-human` is missing.

## 6) Escalation flow
- For blocked/high-risk changes, open escalation issue using template.
- Ensure `needs-human` label is present.
- Stop blocked scope until human decision is recorded.
