## Linked Issue
- [ ] Linked issue provided (`Refs #...` or `Fixes #...`)

## Definition of Done
- [ ] CI is green (`node scripts/validate-workflows.mjs`)
- [ ] No `$env.*` usage and no secrets committed
- [ ] Postgres/HTTP/Telegram error outputs are wired to ERR path -> `WF99`
- [ ] Notes updated on changed workflow nodes
- [ ] `executeQuery` used only under `DB RO` read-only policy (or not used)
- [ ] ACL rules are preserved (group scoped; DM rules unchanged unless approved)
- [ ] Docs updated if constraints/behavior changed

## Scope
**IN:**
- 

**OUT:**
- 

## Validation Evidence
- [ ] `node scripts/validate-workflows.mjs`
- [ ] Manual checks (if applicable) documented

## Risk and Rollback
- Risk:
- Rollback:
