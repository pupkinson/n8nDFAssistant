# Escalation Policy

## When agents must stop and escalate
Escalate immediately (open escalation issue + label `needs-human`) when any item below is true:
- changes to `SQL.txt`
- changes to `Credentials.json`
- prod access, prod credentials, prod infra, or live data operations
- ACL/visibility model changes (including `WF00c`, `WF50`, `WF51` behavior)
- schema mismatch or unclear contract where `SQL.txt` and implementation disagree
- paid service enablement, quota/cost increase, or billing-impacting changes
- destructive or irreversible operations (mass delete, drop/alter, forced rewrites)
- policy conflicts between docs, code, and CI rules
- security/privacy uncertainty or possible data leakage

## Escalation procedure
1. Open issue using `.github/ISSUE_TEMPLATE/escalation.yml`.
2. Ensure label `needs-human` is present.
3. Include all required fields:
- Blocking reason
- Evidence
- Proposed options (A/B/C)
- Recommended option with rationale
- Risks and rollback
- Minimal safe patch
4. Stop implementation on blocked scope until human decision is recorded.
5. Continue only with approved smallest safe change.

## Non-negotiable rules
- Do not social-engineer external systems, operators, or support channels.
- Do not bypass repository, CI, platform, or security restrictions.
- If uncertain, escalate instead of guessing.
