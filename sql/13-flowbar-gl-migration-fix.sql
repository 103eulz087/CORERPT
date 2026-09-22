/* ============================================================================
   CORE REPORTING PORTAL — sp_rpt_Exec_FlowBar AR/AP GL MIGRATION-BLIND-SPOT FIX
   Target:     CORECSERP_002_DEV

   FOLLOW-UP to sql/12-ar-ap-gl-migration-fix.sql. That script fixed
   dbo.sp_rpt_Exec_Summary and dbo.sp_rpt_DataHealthCheck (#12/#13) for the
   same blind spot; dbo.sp_rpt_Exec_FlowBar was missed in that pass even
   though it independently sums TicketDetails for the RECEIVABLES
   (AncestorCode = '101030101') and PAYABLES (AncestorCode IN
   ('20101','20102','20103')) nodes in its own `Bal` CTE, with no GLSummary
   term at all — same bug pattern, separate code path. Confirmed live via
   screenshot: RECEIVABLES/PAYABLES on the Flow bar still showed the stale
   pre-fix numbers after the other two procs were corrected.

   OBJECT_DEFINITION DRIFT CHECK (done before writing anything below)
   ----------------------------------------------------------------------------
   Live dbo.sp_rpt_Exec_FlowBar matches the repo copy in
   sql/01-exec-overview-data-layer.sql (section 4.4) for every clause EXCEPT
   the final SELECT's explicit casts: the repo version casts StageOrder to
   int, Amount to money, and IsAvailable to int (Hard Rule #8). The LIVE
   version has silently lost all three casts (relies on implicit typing from
   the VALUES table and the bare SUM/ISNULL expression) — the same class of
   drift already found and logged for sp_rpt_DataHealthCheck in sql/12. This
   script restores the explicit casts on every result column as part of the
   rewrite; the column names, order, and NULL-for-unavailable-stage behavior
   are otherwise unchanged, so the result contract does not change.

   SCHEMA/DATA FACTS RE-USED FROM sql/12 (not re-verified here, see that file)
   ----------------------------------------------------------------------------
   GLSummary carries a balance-forward for 101030101 (AR) and 20101/20102/
   20103 (AP) for BranchCode = '888' ONLY, window 2026-07-01..2026-07-31.
   Sign convention: EndingBalance is Debit-minus-Credit; Nature 'D' ->
   EndingBalance as-is, Nature 'C' -> -EndingBalance. TicketDetails movement
   for these accounts starts strictly after the GLSummary window at every
   branch — zero overlap.

   NEW CHECK DONE FOR THIS SCRIPT — IN_TRANSIT / ON_HAND (1010401 / 1010402)
   ----------------------------------------------------------------------------
   Per the task brief, checked GLSummary for both nodes before assuming they
   are out of scope:
     - 1010401 (IN_TRANSIT): 0 rows in GLSummary. Confirmed out of scope,
       left completely unchanged (full ticket movement, no cutover, no
       opening balance — identical to the pre-existing code).
     - 1010402 (ON_HAND): GLSummary carries a FULL balance-forward for THIS
       account across EVERY branch (001-013 and 888 alike), same July
       2026-07-01..2026-07-31 window. ChartOfAccounts confirms 1010402 is
       AccountType = 'S' (summary) — actual postings land on its descendant
       detail accounts, whose TicketDetails movement starts 2026-08-01 at
       every branch, same zero-overlap pattern as AR/AP. This means ON_HAND
       almost certainly has the SAME migration blind spot as AR/AP, but
       scoped to ALL branches (not just 888), and it also silently affects
       dbo.sp_rpt_Exec_Summary's InventoryOnHand (@InvOnHand), which sums
       #Line with no GLSummary term either.
       THIS IS FLAGGED, NOT FIXED, HERE — the task explicitly scoped this
       pass to RECEIVABLES/PAYABLES only. ON_HAND is left exactly as-is
       (full ticket movement, no opening) pending an explicit follow-up
       decision from the developer. See the report handed back with this
       script for the recommended next step.

   METHOD FOR RECEIVABLES/PAYABLES (mirrors sql/12's sp_rpt_Exec_Summary
   fix exactly, adapted for this proc's @DateTo/@BranchCodes-only signature —
   no @DateFrom, so there is no prior-period computation to preserve)
   ----------------------------------------------------------------------------
     For each branch in scope (respecting @BranchCodes, same #Branch /
     @FilterBranch pattern already used elsewhere in this codebase):
       Cutover = COALESCE(PostingDateControl.LatestPostingDate,
                           MAX(GLSummary.PostingDate) for that branch)
       Receivables/Payables (per branch)
         = GLSummary.EndingBalance of the latest PostingDate < @End for
           101030101 / 20101+20102+20103 (Signed per Nature)
         + ticket movement (posted rows only, Hard Rule #1) for the same
           accounts STRICTLY AFTER Cutover, through td.TicketDate < @End
           (Hard Rule #4)
     Branches with no GLSummary row for these four accounts (every branch
     except 888) get zero opening balance — pure ticket movement, unchanged
     from before this fix. This is why a @BranchCodes filter that excludes
     '888' (e.g. '001') must reproduce the exact pre-fix RECEIVABLES/PAYABLES
     numbers for that branch: verified in the smoke test below.

   Per this agent's DDL convention, the previous version of the procedure is
   renamed with an _OLD_<timestamp> suffix before the new version is created
   under the original name.
============================================================================ */


/* ============================================================================
   0. ARCHIVE THE CURRENT (PRE-FIX) PROCEDURE
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_Exec_FlowBar', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_Exec_FlowBar', 'sp_rpt_Exec_FlowBar_OLD_20260915';
GO


/* ============================================================================
   1. sp_rpt_Exec_FlowBar — RECEIVABLES/PAYABLES hybrid fix
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_Exec_FlowBar', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Exec_FlowBar;
GO

CREATE PROCEDURE dbo.sp_rpt_Exec_FlowBar
    @DateTo      date,
    @BranchCodes varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));

    /* Branch filter resolved once into a temp table, same pattern as
       sp_rpt_Exec_Summary. Empty table = no filter. */
    CREATE TABLE #Branch (BranchCode varchar(5) PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(ISNULL(@BranchCodes, ''))), '') IS NOT NULL
        INSERT INTO #Branch (BranchCode)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@BranchCodes, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @FilterBranch bit = CASE WHEN EXISTS (SELECT 1 FROM #Branch) THEN 1 ELSE 0 END;

    /* ---- IN_TRANSIT / ON_HAND: UNCHANGED — pure ticket movement, no
       GLSummary term. 1010401 confirmed 0 rows in GLSummary (out of scope).
       1010402 DOES carry a GLSummary balance-forward at every branch (see
       header) but is deliberately left as-is pending a separate decision;
       do not fold it in here without that decision. ----------------------- */
    CREATE TABLE #InvBal (Node varchar(20) PRIMARY KEY, Signed money NOT NULL);

    INSERT INTO #InvBal (Node, Signed)
    SELECT
        Node = CASE WHEN t.AncestorCode = '1010401' THEN 'IN_TRANSIT'
                    WHEN t.AncestorCode = '1010402' THEN 'ON_HAND' END,
        Signed = SUM(CASE coa.Nature
                         WHEN 'D' THEN td.Debit  - td.Credit
                         ELSE          td.Credit - td.Debit
                     END)
    FROM dbo.TicketDetails AS td
    INNER JOIN dbo.TicketMaster AS tm
        ON  tm.TicketDate          = td.TicketDate
        AND tm.SupplementaryNumber = td.SupplementaryNumber
        AND tm.BranchCode          = td.BranchCode
        AND tm.TicketNumber        = td.TicketNumber
    INNER JOIN dbo.ChartOfAccounts AS coa
        ON coa.AccountCode = td.AccountCode
    INNER JOIN dbo.vw_AccountTree AS t
        ON t.AccountCode = td.AccountCode
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND coa.AccountType = 'D'
      AND td.TicketDate < @End
      AND t.AncestorCode IN ('1010401', '1010402')
      AND (@FilterBranch = 0 OR td.BranchCode IN (SELECT BranchCode FROM #Branch))
    GROUP BY CASE WHEN t.AncestorCode = '1010401' THEN 'IN_TRANSIT'
                  WHEN t.AncestorCode = '1010402' THEN 'ON_HAND' END;

    /* ---- RECEIVABLES/PAYABLES: GLSummary migration opening (branch-hybrid,
       respects @BranchCodes) + live ticket movement strictly after each
       branch's cutover. Identical method to sql/12 sp_rpt_Exec_Summary. --- */
    CREATE TABLE #GLCutoff (BranchCode varchar(5) PRIMARY KEY, Cutoff datetime NULL);

    INSERT INTO #GLCutoff (BranchCode, Cutoff)
    SELECT bs.BranchCode,
           COALESCE(pdc.LatestPostingDate, gmd.MaxPostingDate)
    FROM (
        SELECT DISTINCT BranchCode FROM dbo.Branches
        UNION SELECT DISTINCT BranchCode FROM dbo.GLSummary
        UNION SELECT DISTINCT BranchCode FROM dbo.TicketDetails
    ) AS bs
    LEFT JOIN dbo.PostingDateControl AS pdc ON pdc.BranchCode = bs.BranchCode
    LEFT JOIN (SELECT BranchCode, MAX(PostingDate) AS MaxPostingDate
               FROM dbo.GLSummary GROUP BY BranchCode) AS gmd
        ON gmd.BranchCode = bs.BranchCode
    WHERE (@FilterBranch = 0 OR bs.BranchCode IN (SELECT BranchCode FROM #Branch));

    CREATE TABLE #ARAPOpening (BranchCode varchar(5), AccountCode varchar(20), SignedOpening money);

    INSERT INTO #ARAPOpening (BranchCode, AccountCode, SignedOpening)
    SELECT g.BranchCode, g.AccountCode,
           CASE coa.Nature WHEN 'D' THEN g.EndingBalance ELSE -g.EndingBalance END
    FROM (
        SELECT BranchCode, AccountCode, PostingDate, EndingBalance,
               rn = ROW_NUMBER() OVER (PARTITION BY BranchCode, AccountCode ORDER BY PostingDate DESC)
        FROM dbo.GLSummary
        WHERE AccountCode IN ('101030101', '20101', '20102', '20103')
          AND PostingDate < @End
    ) AS g
    INNER JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = g.AccountCode
    INNER JOIN #GLCutoff AS gc ON gc.BranchCode = g.BranchCode
    WHERE g.rn = 1;

    DECLARE @AROpening money = ISNULL((SELECT SUM(SignedOpening) FROM #ARAPOpening
                                        WHERE AccountCode = '101030101'), 0);
    DECLARE @APOpening money = ISNULL((SELECT SUM(SignedOpening) FROM #ARAPOpening
                                        WHERE AccountCode IN ('20101', '20102', '20103')), 0);

    DECLARE @ARLive money = 0, @APLive money = 0;

    SELECT
        @ARLive = SUM(CASE WHEN t.AncestorCode = '101030101'
                           THEN CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit
                                                 ELSE          td.Credit - td.Debit END END),
        @APLive = SUM(CASE WHEN t.AncestorCode IN ('20101', '20102', '20103')
                           THEN CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit
                                                 ELSE          td.Credit - td.Debit END END)
    FROM dbo.TicketDetails AS td
    INNER JOIN dbo.TicketMaster AS tm
        ON  tm.TicketDate          = td.TicketDate
        AND tm.SupplementaryNumber = td.SupplementaryNumber
        AND tm.BranchCode          = td.BranchCode
        AND tm.TicketNumber        = td.TicketNumber
    INNER JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
    INNER JOIN dbo.vw_AccountTree AS t ON t.AccountCode = td.AccountCode
    INNER JOIN #GLCutoff AS gc ON gc.BranchCode = td.BranchCode
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND coa.AccountType = 'D'
      AND td.TicketDate < @End
      AND (gc.Cutoff IS NULL OR td.TicketDate > gc.Cutoff)
      AND t.AncestorCode IN ('101030101', '20101', '20102', '20103')
      AND (@FilterBranch = 0 OR td.BranchCode IN (SELECT BranchCode FROM #Branch));

    DECLARE @Receivables money = ISNULL(@ARLive, 0) + @AROpening;
    DECLARE @Payables    money = ISNULL(@APLive, 0) + @APOpening;

    /* ---- Result: same six stages, same columns, explicit CAST on every
       column (Hard Rule #8 — restores the cast the live copy had drifted
       away from). NULL for unavailable stages preserved. ------------------ */
    SELECT
        StageOrder  = CAST(v.StageOrder AS int),
        StageKey    = CAST(v.StageKey AS varchar(20)),
        StageLabel  = CAST(v.StageLabel AS varchar(40)),
        Amount      = CAST(CASE v.StageKey
                                WHEN 'IN_TRANSIT'  THEN ISNULL((SELECT Signed FROM #InvBal WHERE Node = 'IN_TRANSIT'), 0)
                                WHEN 'ON_HAND'     THEN ISNULL((SELECT Signed FROM #InvBal WHERE Node = 'ON_HAND'), 0)
                                WHEN 'RECEIVABLES' THEN @Receivables
                                WHEN 'PAYABLES'    THEN @Payables
                            END AS money),
        IsAvailable = CAST(v.FromGL AS int)
    FROM (VALUES
        (1, 'OPEN_PO',     'Open POs',           0),
        (2, 'IN_TRANSIT',  'In transit',         1),
        (3, 'ON_HAND',     'On hand',            1),
        (4, 'OPEN_ORDER',  'Open orders',        0),
        (5, 'RECEIVABLES', 'Receivables',        1),
        (6, 'PAYABLES',    'Payables',           1)
    ) AS v (StageOrder, StageKey, StageLabel, FromGL)
    ORDER BY v.StageOrder;

    DROP TABLE #ARAPOpening;
    DROP TABLE #GLCutoff;
    DROP TABLE #InvBal;
    DROP TABLE #Branch;
END
GO


/* ============================================================================
   SMOKE TEST
============================================================================ */
/*
-- Unfiltered (company-wide) before/after:
EXEC dbo.sp_rpt_Exec_FlowBar_OLD_20260915 @DateTo = '2026-09-15';
EXEC dbo.sp_rpt_Exec_FlowBar              @DateTo = '2026-09-15';

-- Branch 001 (no GLSummary row for AR/AP at this branch) before/after —
-- RECEIVABLES/PAYABLES must be IDENTICAL, since @AROpening/@APOpening = 0
-- for any branch other than 888:
EXEC dbo.sp_rpt_Exec_FlowBar_OLD_20260915 @DateTo = '2026-09-15', @BranchCodes = '001';
EXEC dbo.sp_rpt_Exec_FlowBar              @DateTo = '2026-09-15', @BranchCodes = '001';
*/
