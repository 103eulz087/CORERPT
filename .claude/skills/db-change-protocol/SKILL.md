---
name: db-change-protocol
description: The mandatory procedure for any database change (table, stored procedure, function, view, index) in the CORE Reporting Portal. Use whenever creating or altering a DB object.
---

# DB Change Protocol

## Target database
1. DEFAULT for all new/altered DDL: **CORECSERP_002_DEV**. Apply there without
   asking.
2. **CORECSJFC2026_STAGING**: reads are fine; ANY DDL (create/alter/drop of
   tables, SPs, functions, views, indexes) requires explicit developer approval
   FIRST. Ask, wait for yes, then apply.

Credentials: `.claude/db.local.md` (gitignored).

## Every change, every time
1. Read the current definition/schema of the object from DEV before altering it.
   Never alter blind.
2. Write the change as a script saved to `/sql/NN-description.sql` (numbered).
   The script is the source of truth, not an ad-hoc query window.
3. Make the script idempotent/replayable where reasonable
   (`IF OBJECT_ID(...) IS NOT NULL DROP ...` then `CREATE`).
4. Apply to DEV. Run a smoke test (an EXEC block or SELECT) in the same script,
   commented out below the object.
5. Report to the developer: what changed, why, and the smoke-test result.
6. For STAGING: show the developer the exact script and ask before applying.

## Reporting objects are read-only
Every `sp_rpt_*` only SELECTs. If a change would INSERT/UPDATE/DELETE a base
table, that is out of scope for this portal — stop and flag it.

## Never
- Never put credentials in a committed file.
- Never apply DDL to STAGING without a yes.
- Never leave a change applied that isn't captured in `/sql/`.
