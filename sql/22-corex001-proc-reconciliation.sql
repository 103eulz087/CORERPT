/* ============================================================================
   CORE REPORTING PORTAL — COREX001 PROC RECONCILIATION 2026-09-26
   Target: COREX001 only. CORECSERP_002_DEV is the source of truth here and
   was not modified. CORECSJFC2026_STAGING was not touched.

   WHAT HAPPENED
   ----------------------------------------------------------------------------
   When the developer copied sp_rpt_* procs/functions from CORECSERP_002_DEV
   to the new COREX001 database (created 2026-09-25, see CLAUDE.md), the copy
   also carried over two separate defects:

   1. COREX001 was left at SQL Server compatibility level 120 (the instance
      default), not 160 — STRING_SPLIT (used by nearly every sp_rpt_* proc's
      CSV filter params) requires 130+, so every filtered report threw
      "Invalid object name 'STRING_SPLIT'". Fixed separately, same day:
      ALTER DATABASE COREX001 SET COMPATIBILITY_LEVEL = 160
      (matches sql/04-dev-compat-level-160.sql's fix to CORECSERP_002_DEV on
      2026-09-11 — same defect, new database, not previously applied here).

   2. A full comparison of all 56 sp_rpt_* procs present in both databases
      (byte-for-byte after normalizing line-endings and [dbo].[x] vs dbo.x
      bracket-quoting noise — cosmetic scripting-tool artifacts, not real
      differences) found exactly 3 procs on COREX001 that did NOT match
      CORECSERP_002_DEV's current, already-fixed versions:

      - sp_rpt_Exec_BranchScorecard — literal typo: `FROM dbo.Branch AS b`
        (singular) instead of `FROM dbo.Branches AS b` (plural, correct).
        Threw "Invalid object name 'dbo.Branch'" — the error that surfaced
        this whole investigation. Not a logic bug, a corrupted table name.

      - sp_rpt_BalanceSheetLiveWithDate — missing the posted-only filter
        (Hard Rule #1) on its live-activity leg. Without it, REVERSED/draft
        tickets can leak into the live balance sheet figures — this is
        EXACTLY the bug sql/11-fix-live-proc-posted-status-filter.sql
        already fixed on CORECSERP_002_DEV (documented there: "TicketNumber
        5194, branch 888, REVERSED, was inflating this branch's figures").
        COREX001 was running the PRE-fix version. This is a SILENT
        correctness bug, not an error — it would have produced confidently
        wrong numbers with no indication anything was off.

      - sp_rpt_IncomeStatementLiveWithDate — the SAME missing posted-only
        filter as above, PLUS a `PostingDate BETWEEN @DateFrom AND @DateTo`
        (Hard Rule #4 violation — never BETWEEN on a datetime column).
        DEV's version already replaced this with
        `>= @DateFrom AND < DATEADD(DAY,1,@DateTo)`. The BETWEEN form is
        harmless TODAY only because every GLSummary row in this data happens
        to post at midnight — fragile, not something to rely on.

   Root cause for all three: COREX001's copy was taken from an EARLIER point
   in CORECSERP_002_DEV's history than 2026-09-26 — before these three fixes
   existed there. This is exactly the "COREX001 can silently drift behind
   DEV's latest fixes" risk CLAUDE.md's DB protocol section already warns
   about (originally written after a similar Exception Center regression the
   same day) — this reconciliation is a second, independent confirmation of
   that same risk class, this time in pre-existing ERP-adjacent statement
   procs rather than a portal-authored one.

   THE FIX
   ----------------------------------------------------------------------------
   All 3 procs' CURRENT LIVE definitions were pulled fresh from
   CORECSERP_002_DEV via OBJECT_DEFINITION() and applied to COREX001,
   replacing the stale/corrupted versions — not re-derived or retyped, to
   guarantee an exact match. Old (defective) COREX001 versions renamed to
   *_OLD_20260926, not dropped, per the DB change protocol.

   VERIFICATION PERFORMED
   ----------------------------------------------------------------------------
   - All 3 synced procs confirmed byte-identical to CORECSERP_002_DEV
     (post-normalization) immediately after applying.
   - sp_rpt_Exec_BranchScorecard re-run live on COREX001 with a real date
     range: returns 15 branch rows, no error (previously threw "Invalid
     object name 'dbo.Branch'").
   - Full re-comparison of ALL 56 sp_rpt_* procs present in both databases,
     post-fix: 0 differences remain. Also confirmed no proc is missing from
     COREX001 or present there but not in DEV (aside from each database's own
     _OLD_* rollback history, which is expected to differ and is not
     compared).

   This file is a record only — the fix was applied directly via each proc's
   current OBJECT_DEFINITION(), not by re-typing SQL here (that would risk
   transcribing a new, third variant instead of guaranteeing an exact match
   to DEV). If this needs to be replayed, re-run the same comparison-and-sync
   approach: pull OBJECT_DEFINITION() from CORECSERP_002_DEV for the proc(s)
   found to differ, rename the COREX001 version to *_OLD_<date>, and apply.
============================================================================ */
