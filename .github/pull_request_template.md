# Summary
<!-- 2–6 bullets: what changed and why. No marketing. -->

- 
- 

## Linked Issue
<!-- Use "Refs #123" while work is in progress.
     Use "Fixes #123" only when you want the issue to auto-close on merge. -->
Refs #

## Scope
<!-- What is INCLUDED / NOT INCLUDED to prevent scope creep. -->
**IN:**
- 

**OUT:**
- 

## How to Test
<!-- Exact commands + manual steps. Must be reproducible by someone else. -->
### Automated
- [ ] `...` (e.g. npm test / pnpm test)
- [ ] `...` (e.g. npm run lint)
- [ ] `...` (e.g. npm run build)

### Manual
1. 
2. 
3. 

## Demo / Screenshots (required for UI changes)
<!-- Provide before/after screenshots or a short video/gif. -->
- 

## Data / Migrations
<!-- Fill ONLY if DB schema/data changes. -->
- [ ] No DB changes
- [ ] DB migration included (link to migration files):
  - 
- [ ] Backward/forward compatibility considered
- [ ] Rollback plan documented (how to revert safely):
  - 

## Observability / Logging
- [ ] Logs are meaningful (no secrets, no noisy spam)
- [ ] Errors are handled (no silent failures)
- [ ] Metrics/tracing updated (if applicable)

## Security & Privacy
- [ ] No secrets committed (keys, tokens, passwords)
- [ ] Input validation added/updated (if applicable)
- [ ] AuthZ checked (who can do what) (if applicable)
- [ ] Dependencies reviewed (no unnecessary new deps)

## Quality Gates (Definition of Done)
<!-- PR should not be merged unless all relevant boxes are checked. -->
- [ ] CI is green (lint/tests/build)
- [ ] Code reviewed (required reviewers assigned or CODEOWNERS triggered)
- [ ] Unit tests added/updated for new behavior
- [ ] Edge cases considered (empty/error states, invalid inputs)
- [ ] Documentation updated (README / runbook / API docs) if needed
- [ ] Breaking changes clearly called out (or confirmed "none")
- [ ] Feature flag used (if rollout needs safety) / or "not needed"
- [ ] Ready for QA on staging (if your process uses staging)

## Risks
<!-- Be honest: what can break, what’s uncertain. -->
- Risk:
- Mitigation:
- Rollback:

## Notes for Reviewer
<!-- Point reviewers to the tricky parts and files. -->
- 
