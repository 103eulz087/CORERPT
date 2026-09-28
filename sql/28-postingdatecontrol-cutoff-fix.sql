/* ============================================================================
   CORE REPORTING PORTAL — POSTINGDATECONTROL / FROZEN-CUTOFF FIX
   Target: COREX001 (current default dev tier per CLAUDE.md's 2026-09-27
   working-tree update — verified by reading the file directly off disk,
   not via git, per this task's instruction and this repo's own documented
   stale-read incidents; CORECSJFC2026_STAGING NOT touched).

   *** PARTIAL REVERT 2026-09-29 — sp_rpt_BalanceSheetLiveWithDate and
   sp_rpt_IncomeStatementLiveWithDate ROLLED BACK, the other 3 procs stay ***
   ----------------------------------------------------------------------------
   An independent accounting-reviewer pass confirmed sp_rpt_Exec_Summary,
   sp_rpt_DataHealthCheck, and sp_rpt_Exec_FlowBar are correct and shipped —
   PayablesTrade re-derived from scratch and confirmed at 872,624,045.07
   (the earlier ~836.4M estimate under-scoped the fix; the pre-fix 807.49M
   was the confirmed-buggy original). Those 3 stay on today's fix, no
   further action needed.

   sp_rpt_BalanceSheetLiveWithDate and sp_rpt_IncomeStatementLiveWithDate
   were NOT shipped. Broadening the per-(branch,account) activity-filtered
   cutoff from just the 4 AR/AP control accounts to the ENTIRE chart of
   accounts introduced a genuine regression the reviewer caught: the
   consolidated (@BranchCode=NULL) live balance sheet used to foot EXACTLY
   (TotalAssets 1,561,590,448.74 = TotalLiabilities 919,499,461.54 +
   TotalEquity 642,090,987.20, zero variance, confirmed pre-fix) but broke by
   13,776,139.85 after this fix (TotalAssets 1,642,687,541.03 vs.
   Liab+Equity 1,628,911,401.18). Root cause (reviewer's hypothesis,
   corroborated by the gap landing within ~$47,943 of Health Check #12's own
   AR-vs-GL gap): different legs of the same journal entry (e.g. an AR leg
   and its offsetting Revenue leg) can now freeze on DIFFERENT dates once
   every account gets its own independently-computed cutoff instead of one
   shared per-branch cutoff — GLSummary is confirmed NOT a perfectly
   faithful mirror of ticket activity even within its own still-active
   window (branch 001's AR GLSummary debits underrun posted-ticket debits by
   ~$2.03M even before any freeze), so mismatched cutoffs on the two legs of
   one entry can silently break double-entry symmetry that a single shared
   cutoff preserved by construction.

   Reverted by renaming the 2026-09-29 (footing-broken) versions of these
   two procs to `_UNFOOTED_20260929` (preserved, not dropped) and restoring
   their `_OLD_20260929` (pre-this-fix) bodies back under the original
   names. Re-verified live post-revert: the consolidated balance sheet foots
   exactly again (919,499,461.54 + 642,090,987.20 = 1,561,590,448.74).

   KNOWN COST OF THIS REVERT: these two procs are back to their PRE-fix
   behavior, which means they once again silently drop real ledger activity
   for any account with a stale/zero GLSummary presence at the per-branch
   cutoff their (old) shared-cutoff design uses — the exact defect this
   whole investigation started from (e.g. confirmed: 101040102 INVENTORY IN
   TRANSIT's real 15,858,339.90 of August activity at branch 888 goes back
   to being dropped; the Aug 2026 company-wide Income Statement reverts from
   Revenue 130.85M/COGS 142.77M back to the understated 83.86M/100.91M this
   investigation was never able to fully trust). This is a deliberate,
   temporary trade — a report that foots but understates some accounts,
   over one that captures more real activity but doesn't foot — pending a
   proper fix. See the reviewer's two suggested directions in the review
   transcript: (a) one shared, carefully-computed cutoff per branch (the
   MOST CONSERVATIVE activity-filtered cutoff across every account in that
   branch, not PostingDateControl), or (b) keep per-account cutoffs but add
   an automatic system-wide footing assertion so a future regression here is
   caught by Data Health Check rather than requiring a manual re-derivation.
   NEITHER has been built yet — this is flagged as follow-up work, not done.

   ROOT CAUSE (builds on sql/12, sql/13, sql/11, and sql/27's investigation)
   ----------------------------------------------------------------------------
   sql/12 and sql/13 (2026-09-15) introduced a hybrid GL-migration-opening +
   live-ticket-movement pattern for AR/AP control accounts, using:
       COALESCE(PostingDateControl.LatestPostingDate, MAX(GLSummary.PostingDate))
   as the per-branch cutover date between "trust GLSummary" and "trust live
   TicketDetails". At the time, dbo.PostingDateControl was confirmed EMPTY
   (0 rows), so the COALESCE was a documented safe no-op that always fell
   through to MAX(GLSummary.PostingDate).

   Both assumptions have since broken, independently confirmed live today
   (2026-09-29) and re-verified twice:

   1. PostingDateControl is no longer empty — it now has 15 rows (all
      branches, 001-014, 888) and EVERY row reads LatestPostingDate =
      2026-08-31, regardless of branch or account. This value does not
      reflect when any given account's GLSummary feed actually went stale;
      it appears to track "period closed for posting" (an ERP workflow
      concept), not "GLSummary rollup is current" — a different fact the
      original 2026-09-15 authors did not anticipate needing to distinguish
      (same finding sql/27 made independently for sp_rpt_BankReconciliation-
      WithDate on 2026-09-28).

   2. The COALESCE's fallback, bare MAX(GLSummary.PostingDate), is ALSO now
      unsafe on its own, for the same reason sql/27 discovered: GLSummary
      keeps inserting a row every single day per (BranchCode, AccountCode)
      even after its real feed has gone stale — the frozen rows simply carry
      the prior day's EndingBalance forward with Debits = Credits = 0. So
      naive MAX(PostingDate) resolves to "today" (2026-08-31, the last row
      in this snapshot) for accounts that actually stopped receiving real
      postings weeks or months earlier. Dropping PostingDateControl alone
      and falling back to naive MAX(PostingDate) would NOT fix this bug —
      it would reproduce the identical staleness via a different code path.

   CONFIRMED LIVE: PER-(BRANCH, ACCOUNT) FREEZE DATES VARY WIDELY, EVEN
   WITHIN THE SAME BRANCH — A SINGLE PER-BRANCH CUTOFF IS NOT VALID
   ----------------------------------------------------------------------------
   Querying MAX(GLSummary.PostingDate) WHERE (Debits<>0 OR Credits<>0),
   grouped by (BranchCode, AccountCode), for the four AR/AP control accounts:

     Branch 888: AR (101030101) last real activity 2026-08-17
                 AP-Trade (20101)      last real activity 2026-07-01
                 AP-Others (20102)     last real activity 2026-07-01
                 AP-Accrued (20103)    last real activity 2026-08-31 (not frozen)
     Branch 001: AR last real activity 2026-08-14; AP-Trade 2026-08-19;
                 AP-Accrued 2026-08-31 (not frozen)
     (full per-branch/account table verified live before writing anything
      below — 31 rows, AR/AP-Trade/AP-Others/AP-Accrued × every branch that
      has a GLSummary row for that account)

   This directly falsifies the task brief's working assumption that a single
   per-branch cutoff might still be valid once the activity filter is added:
   it is not. The fix below is keyed by (BranchCode, AccountCode) everywhere
   a cutoff is computed, for all 5 procs — including sp_rpt_BalanceSheet-
   LiveWithDate / sp_rpt_IncomeStatementLiveWithDate, whose existing
   BranchCutoff was a single per-branch value applied uniformly to EVERY
   account in that branch's balance sheet / income statement, not just
   AR/AP. Re-running the same per-(branch,account) activity-filtered MAX
   across ALL GLSummary accounts (not just AR/AP) confirms the same
   divergence generally: e.g. branch 001 has 12 distinct activity-filtered
   cutoff dates across its 76 GLSummary-covered accounts, branch 888 has 13
   distinct dates across 146 accounts — a single per-branch value would be
   wrong for most of those accounts.

   THE FIX (per the task brief's proven pattern, sql/27 STEP 3/4)
   ----------------------------------------------------------------------------
   Every place that computed:
       COALESCE(PostingDateControl.LatestPostingDate, MAX(GLSummary.PostingDate))
   is replaced with an activity-filtered, per-(BranchCode, AccountCode) cutoff:
       MAX(GLSummary.PostingDate)
       WHERE BranchCode = <branch> AND AccountCode = <account>
         AND (Debits <> 0 OR Credits <> 0)
   PostingDateControl is not read at all by any of the 5 procs below — its
   join is dropped entirely, not "fixed" (its data is a different, unrelated
   fact per the finding above; no attempt is made to reinterpret it here).

   The `Debits<>0 OR Credits<>0` filter is safe because `EndingBalance =
   BeginningBalance + Debits + Credits` is a hard structural invariant in
   this data with zero exceptions (re-confirmed today, same as sql/27's
   finding) — a day with both zero can never represent real balance-moving
   activity, so the heuristic cannot mistake a genuine zero-activity day for
   a dead feed.

   OBJECT_DEFINITION DRIFT CHECK (done before writing anything below, per
   this repo's shared/live-proc protocol)
   ----------------------------------------------------------------------------
   Pulled live OBJECT_DEFINITION() for all 5 procs immediately before this
   script was written and diffed against sql/12, sql/13, sql/11 on disk:
   byte-for-byte identical (only encoding-artifact differences in em-dash
   characters and bracket-quoting of the proc name, no functional drift).
   sys.objects confirms sp_rpt_BalanceSheetLiveWithDate / sp_rpt_
   IncomeStatementLiveWithDate were last recreated 2026-09-26 (an unrelated
   rename-preserve pass, _OLD_20260926 already exists there from that prior
   change — untouched by this script) but their bodies still match sql/11
   exactly. No stale-read risk found; safe to build directly on these.

   OBJECTS TOUCHED, AND HOW EACH ONE'S CUTOFF SCOPE DIFFERS
   ----------------------------------------------------------------------------
   1. sp_rpt_Exec_Summary       — #GLCutoff (previously BranchCode-only PK)
                                   becomes (BranchCode, AccountCode)-keyed,
                                   built via CROSS JOIN of in-scope branches ×
                                   the 4 AR/AP accounts (101030101, 20101,
                                   20102, 20103). #ARAPOpening and the
                                   @ARLive/@APLive query now join #GLCutoff on
                                   both columns instead of BranchCode alone.
                                   Nothing else in the proc changes.
   2. sp_rpt_DataHealthCheck     — identical fix applied to #GLCutoffHC /
                                   @ARLiveHC / @APLiveHC (checks #12/#13
                                   only). #ARAPOpeningHC did not reference
                                   the cutoff table before and still doesn't
                                   (it only needs "latest row < @AsOfEnd",
                                   which already correctly reflects the
                                   frozen carried-forward EndingBalance) —
                                   left untouched. Checks 1-11, 14-18
                                   unchanged verbatim.
   3. sp_rpt_Exec_FlowBar        — identical fix, same 4 AR/AP accounts,
                                   adapted for this proc's @DateTo/
                                   @BranchCodes-only signature (no
                                   @DateFrom). IN_TRANSIT/ON_HAND stages are
                                   untouched (they never had a GLSummary
                                   term — see sql/13's header).
   4. sp_rpt_BalanceSheetLiveWithDate    — BROADER SCOPE than #1-3: the
                                   pre-existing BranchCutoff applied one
                                   cutoff per branch to EVERY account in that
                                   branch's balance sheet, not just AR/AP.
                                   Replaced with an AccountCutoff CTE keyed
                                   by (BranchCode, AccountCode), built
                                   directly from GLSummary's own rows (LEFT
                                   JOIN from TicketDetails, so an account
                                   that never had any GLSummary row at all
                                   still gets Cutoff = NULL, falling back to
                                   full ticket history exactly as before).
                                   BranchScope/GLMaxDate/BranchCutoff CTEs
                                   removed (no longer needed — PostedPerBranch
                                   already filtered GLSummary directly by
                                   @BranchCode and did not depend on them).
                                   PostedPerBranch/LatestPerBranch/
                                   BranchAccountCombined logic unchanged.
   5. sp_rpt_IncomeStatementLiveWithDate — same AccountCutoff redesign as #4,
                                   applied to its LiveActivity CTE. Hard
                                   Rule #4 date-range fix and Hard Rule #1
                                   TicketMaster/Status join from sql/11 are
                                   preserved unchanged. PostedActivity CTE
                                   unchanged.

   Per this agent's DDL convention, the previous (pre-this-fix) version of
   each procedure is renamed with an _OLD_20260929 suffix before the new
   version is created under the original name.
============================================================================ */


/* ============================================================================
   0. ARCHIVE THE CURRENT (PRE-FIX) PROCEDURES
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_Exec_Summary', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_Exec_Summary', 'sp_rpt_Exec_Summary_OLD_20260929';
GO

IF OBJECT_ID('dbo.sp_rpt_DataHealthCheck', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_DataHealthCheck', 'sp_rpt_DataHealthCheck_OLD_20260929';
GO

IF OBJECT_ID('dbo.sp_rpt_Exec_FlowBar', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_Exec_FlowBar', 'sp_rpt_Exec_FlowBar_OLD_20260929';
GO

IF OBJECT_ID('dbo.sp_rpt_BalanceSheetLiveWithDate', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_BalanceSheetLiveWithDate', 'sp_rpt_BalanceSheetLiveWithDate_OLD_20260929';
GO

IF OBJECT_ID('dbo.sp_rpt_IncomeStatementLiveWithDate', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_IncomeStatementLiveWithDate', 'sp_rpt_IncomeStatementLiveWithDate_OLD_20260929';
GO


/* ============================================================================
   1. sp_rpt_Exec_Summary — per-(branch,account) activity-filtered cutoff
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_Exec_Summary', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Exec_Summary;
GO

CREATE PROCEDURE dbo.sp_rpt_Exec_Summary
    @DateFrom    date,
    @DateTo      date,
    @BranchCodes varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End       datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @Start     datetime = CAST(@DateFrom AS datetime);

    /* Prior period = same number of days, immediately before @DateFrom */
    DECLARE @Days      int      = DATEDIFF(DAY, @DateFrom, @DateTo) + 1;
    DECLARE @PriorFrom datetime = DATEADD(DAY, -@Days, @Start);
    DECLARE @PriorEnd  datetime = @Start;

    /* Branch filter resolved once into a temp table.
       Empty table = no filter. */
    CREATE TABLE #Branch (BranchCode varchar(5) PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(ISNULL(@BranchCodes, ''))), '') IS NOT NULL
        INSERT INTO #Branch (BranchCode)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@BranchCodes, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @FilterBranch bit = CASE WHEN EXISTS (SELECT 1 FROM #Branch) THEN 1 ELSE 0 END;

    /* ---- Pull every posted detail line once, signed, tagged ------------- */
    CREATE TABLE #Line
    (
        AccountCode varchar(20)  NOT NULL,
        BranchCode  varchar(5)   NOT NULL,
        TicketDate  datetime     NOT NULL,
        Signed      money        NOT NULL,
        Book        char(2)      NOT NULL   -- 'IS' or 'BS'
    );

    INSERT INTO #Line (AccountCode, BranchCode, TicketDate, Signed, Book)
    SELECT
        td.AccountCode,
        td.BranchCode,
        td.TicketDate,
        Signed = CASE coa.Nature
                     WHEN 'D' THEN td.Debit  - td.Credit
                     ELSE          td.Credit - td.Debit
                 END,
        coa.YearEndIndicator
    FROM dbo.TicketDetails AS td
    INNER JOIN dbo.TicketMaster AS tm
        ON  tm.TicketDate          = td.TicketDate
        AND tm.SupplementaryNumber = td.SupplementaryNumber
        AND tm.BranchCode          = td.BranchCode
        AND tm.TicketNumber        = td.TicketNumber
    INNER JOIN dbo.ChartOfAccounts AS coa
        ON coa.AccountCode = td.AccountCode
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND coa.AccountType = 'D'
      AND td.TicketDate < @End           -- BS needs everything up to @DateTo
      AND (@FilterBranch = 0
           OR td.BranchCode IN (SELECT BranchCode FROM #Branch));

    /* ---- Income statement: movement inside the window ------------------- */
    DECLARE
        @NetSales      money = 0, @NetSalesPrior  money = 0,
        @COGS          money = 0, @COGSPrior      money = 0,
        @OpEx          money = 0, @OpExPrior      money = 0,
        @OtherIncome   money = 0;

    SELECT
        @NetSales     = SUM(CASE WHEN t.AncestorCode IN ('401','402','40103')
                                  AND l.TicketDate >= @Start THEN l.Signed END),
        @NetSalesPrior= SUM(CASE WHEN t.AncestorCode IN ('401','402','40103')
                                  AND l.TicketDate >= @PriorFrom
                                  AND l.TicketDate <  @PriorEnd THEN l.Signed END),
        @OtherIncome  = SUM(CASE WHEN t.AncestorCode IN ('403','404','405')
                                  AND l.TicketDate >= @Start THEN l.Signed END),
        @COGS         = SUM(CASE WHEN t.AncestorCode = '5'
                                  AND l.TicketDate >= @Start THEN l.Signed END),
        @COGSPrior    = SUM(CASE WHEN t.AncestorCode = '5'
                                  AND l.TicketDate >= @PriorFrom
                                  AND l.TicketDate <  @PriorEnd THEN l.Signed END),
        @OpEx         = SUM(CASE WHEN t.AncestorCode = '6'
                                  AND l.TicketDate >= @Start THEN l.Signed END),
        @OpExPrior    = SUM(CASE WHEN t.AncestorCode = '6'
                                  AND l.TicketDate >= @PriorFrom
                                  AND l.TicketDate <  @PriorEnd THEN l.Signed END)
    FROM #Line AS l
    INNER JOIN dbo.vw_AccountTree AS t
        ON t.AccountCode = l.AccountCode
    WHERE l.Book = 'IS';

    /* SALES DISCOUNT (40103) has Nature 'D' while its parent REVENUE is 'C',
       so its signed value is already negative against sales. Net Sales above
       is therefore net of discount with no extra subtraction. */

    /* ---- Balance sheet: cumulative to @DateTo --------------------------- */
    DECLARE
        @Cash        money = 0,
        @ARTrade     money = 0,
        @APTrade     money = 0,
        @InvOnHand   money = 0,
        @InvInTransit money = 0;

    SELECT
        @Cash         = SUM(CASE WHEN t.AncestorCode IN ('10101','10102')  THEN l.Signed END),
        @InvOnHand    = SUM(CASE WHEN t.AncestorCode = '1010402'           THEN l.Signed END),
        @InvInTransit = SUM(CASE WHEN t.AncestorCode = '1010401'           THEN l.Signed END)
    FROM #Line AS l
    INNER JOIN dbo.vw_AccountTree AS t
        ON t.AccountCode = l.AccountCode
    WHERE l.Book = 'BS';

    /* ---- AR/AP control accounts: GLSummary migration opening + live ticket
       movement after each (branch, account)'s OWN activity-filtered cutoff.
       FIX 2026-09-29 (db-report-engineer, sql/28): #GLCutoff is now keyed by
       (BranchCode, AccountCode), not BranchCode alone — confirmed live that
       different AR/AP accounts within the SAME branch go stale on very
       different dates (see this file's header). PostingDateControl is no
       longer read (see header root-cause finding); Cutoff is the last
       GLSummary PostingDate with real activity (Debits<>0 OR Credits<>0)
       for that exact (branch, account) pair — NULL if that pair never had
       a GLSummary row at all, in which case full ticket history counts,
       unchanged from before. ------------------------------------------- */
    CREATE TABLE #GLCutoff
    (
        BranchCode  varchar(5)  NOT NULL,
        AccountCode varchar(20) NOT NULL,
        Cutoff      datetime    NULL,
        PRIMARY KEY (BranchCode, AccountCode)
    );

    INSERT INTO #GLCutoff (BranchCode, AccountCode, Cutoff)
    SELECT bs.BranchCode, acct.AccountCode,
           (SELECT MAX(g.PostingDate)
            FROM dbo.GLSummary AS g
            WHERE g.BranchCode  = bs.BranchCode
              AND g.AccountCode = acct.AccountCode
              AND (g.Debits <> 0 OR g.Credits <> 0))
    FROM (
        SELECT DISTINCT BranchCode FROM dbo.Branches
        UNION SELECT DISTINCT BranchCode FROM dbo.GLSummary
        UNION SELECT DISTINCT BranchCode FROM dbo.TicketDetails
    ) AS bs
    CROSS JOIN (VALUES ('101030101'), ('20101'), ('20102'), ('20103')) AS acct(AccountCode)
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
    INNER JOIN #GLCutoff AS gc ON gc.BranchCode = g.BranchCode AND gc.AccountCode = g.AccountCode
    WHERE g.rn = 1;

    DECLARE @AROpening money = ISNULL((SELECT SUM(SignedOpening) FROM #ARAPOpening
                                        WHERE AccountCode = '101030101'), 0);
    DECLARE @APOpening money = ISNULL((SELECT SUM(SignedOpening) FROM #ARAPOpening
                                        WHERE AccountCode IN ('20101', '20102', '20103')), 0);

    DECLARE @ARLive money = 0, @APLive money = 0;

    SELECT
        @ARLive = SUM(CASE WHEN t.AncestorCode = '101030101' THEN l.Signed END),
        @APLive = SUM(CASE WHEN t.AncestorCode IN ('20101', '20102', '20103') THEN l.Signed END)
    FROM #Line AS l
    INNER JOIN dbo.vw_AccountTree AS t ON t.AccountCode = l.AccountCode
    INNER JOIN #GLCutoff AS gc ON gc.BranchCode = l.BranchCode AND gc.AccountCode = l.AccountCode
    WHERE l.Book = 'BS'
      AND t.AncestorCode IN ('101030101', '20101', '20102', '20103')
      AND (gc.Cutoff IS NULL OR l.TicketDate > gc.Cutoff);

    SET @ARTrade = ISNULL(@ARLive, 0) + @AROpening;
    SET @APTrade = ISNULL(@APLive, 0) + @APOpening;

    SELECT
        AsOf              = SYSDATETIME(),
        DateFrom          = @DateFrom,
        DateTo            = @DateTo,
        NetSales          = ISNULL(@NetSales, 0),
        NetSalesPrior     = ISNULL(@NetSalesPrior, 0),
        OtherIncome       = ISNULL(@OtherIncome, 0),
        COGS              = ISNULL(@COGS, 0),
        COGSPrior         = ISNULL(@COGSPrior, 0),
        GrossProfit       = ISNULL(@NetSales, 0) - ISNULL(@COGS, 0),
        GrossMarginPct    = CASE WHEN ISNULL(@NetSales, 0) = 0 THEN NULL
                                 ELSE (ISNULL(@NetSales,0) - ISNULL(@COGS,0))
                                      * 100.0 / @NetSales END,
        GrossMarginPctPrior = CASE WHEN ISNULL(@NetSalesPrior, 0) = 0 THEN NULL
                                 ELSE (ISNULL(@NetSalesPrior,0) - ISNULL(@COGSPrior,0))
                                      * 100.0 / @NetSalesPrior END,
        OperatingExpense  = ISNULL(@OpEx, 0),
        OperatingExpensePrior = ISNULL(@OpExPrior, 0),
        NetIncome         = ISNULL(@NetSales,0) + ISNULL(@OtherIncome,0)
                            - ISNULL(@COGS,0) - ISNULL(@OpEx,0),
        CashPosition      = ISNULL(@Cash, 0),
        ReceivablesTrade  = ISNULL(@ARTrade, 0),
        PayablesTrade     = ISNULL(@APTrade, 0),
        InventoryOnHand   = ISNULL(@InvOnHand, 0),
        InventoryInTransit= ISNULL(@InvInTransit, 0);

    DROP TABLE #ARAPOpening;
    DROP TABLE #GLCutoff;
    DROP TABLE #Line;
    DROP TABLE #Branch;
END
GO


/* ============================================================================
   2. sp_rpt_DataHealthCheck — checks #12/#13 GL-side per-(branch,account) fix
   Rebuilt from the LIVE 18-check definition (confirmed via OBJECT_DEFINITION
   before editing, byte-for-byte match to sql/12). Checks 1-11 and 14-18 are
   copied verbatim, unchanged. Only the @ARGL / @APGL cutoff computation
   inside checks #12/#13 changes; @ARSubledger/@APSubledger are untouched.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_DataHealthCheck', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_DataHealthCheck;
GO

CREATE PROCEDURE dbo.sp_rpt_DataHealthCheck
    @DateFrom  date,
    @DateTo    date,
    @AsOfDate  date = NULL          -- AR/AP/AP-EXP checks; defaults to @DateTo
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @Start datetime = CAST(@DateFrom AS datetime);

    SET @AsOfDate = ISNULL(@AsOfDate, @DateTo);
    DECLARE @AsOfEnd datetime = DATEADD(DAY, 1, CAST(@AsOfDate AS datetime));

    CREATE TABLE #Result
    (
        Seq        int,
        CheckName  varchar(80),
        Severity   varchar(10),
        Findings   int,
        ValueAtRisk money NULL
    );

    /* ---- 1. Standard tickets: must balance on their own ---------------- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 1, 'Unbalanced tickets (standard)', 'CRITICAL',
           COUNT(*), SUM(ABS(x.Variance))
    FROM (
        SELECT Variance = SUM(td.Debit) - SUM(td.Credit)
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        LEFT JOIN dbo.RptMnemonicMap AS mm ON mm.Mnemonic = tm.Mnemonic
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND td.TicketDate >= @Start AND td.TicketDate < @End
          AND ISNULL(mm.IsCrossBranch, 0) = 0
        GROUP BY td.TicketDate, td.SupplementaryNumber, td.BranchCode, td.TicketNumber
        HAVING SUM(td.Debit) <> SUM(td.Credit)
    ) AS x;

    /* ---- 2. Cross-branch sets: must balance across ReferenceNumber ----- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 2, 'Unbalanced cross-branch sets', 'CRITICAL',
           COUNT(*), SUM(ABS(x.Variance))
    FROM (
        SELECT Variance = SUM(td.Debit) - SUM(td.Credit)
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        INNER JOIN dbo.RptMnemonicMap AS mm
            ON mm.Mnemonic = tm.Mnemonic AND mm.IsCrossBranch = 1
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND td.TicketDate >= @Start AND td.TicketDate < @End
        GROUP BY tm.ReferenceNumber
        HAVING SUM(td.Debit) <> SUM(td.Credit)
    ) AS x;

    /* ---- 3. Orphan detail rows ---------------------------------------- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 3, 'Orphan detail rows', 'CRITICAL',
           COUNT(*), SUM(td.Debit + td.Credit)
    FROM dbo.TicketDetails AS td
    WHERE td.TicketDate >= @Start AND td.TicketDate < @End
      AND NOT EXISTS (
            SELECT 1 FROM dbo.TicketMaster AS tm
            WHERE tm.TicketDate          = td.TicketDate
              AND tm.SupplementaryNumber = td.SupplementaryNumber
              AND tm.BranchCode          = td.BranchCode
              AND tm.TicketNumber        = td.TicketNumber);

    /* ---- 4. Postings to summary accounts ------------------------------ */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 4, 'Postings to summary accounts', 'CRITICAL',
           COUNT(*), SUM(td.Debit + td.Credit)
    FROM dbo.TicketDetails AS td
    INNER JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
    WHERE td.TicketDate >= @Start AND td.TicketDate < @End
      AND coa.AccountType = 'S';

    /* ---- 5. Unknown account codes: value invisible to all reporting ---- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 5, 'Unknown account codes', 'CRITICAL',
           COUNT(DISTINCT td.AccountCode), SUM(td.Debit + td.Credit)
    FROM dbo.TicketDetails AS td
    WHERE td.TicketDate >= @Start AND td.TicketDate < @End
      AND NOT EXISTS (SELECT 1 FROM dbo.ChartOfAccounts AS coa
                      WHERE coa.AccountCode = td.AccountCode);

    /* ---- 6. Unmapped mnemonics ---------------------------------------- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 6, 'Unmapped mnemonics', 'WARNING', COUNT(DISTINCT tm.Mnemonic), NULL
    FROM dbo.TicketMaster AS tm
    WHERE tm.TicketDate >= @Start AND tm.TicketDate < @End
      AND tm.Status IN ('POSTED','UPDATED')
      AND tm.Mnemonic IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.RptMnemonicMap AS mm
                      WHERE mm.Mnemonic = tm.Mnemonic);

    /* ---- 7. Unknown branch codes -------------------------------------- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 7, 'Unknown branch codes', 'WARNING', COUNT(DISTINCT td.BranchCode), NULL
    FROM dbo.TicketDetails AS td
    WHERE td.TicketDate >= @Start AND td.TicketDate < @End
      AND NOT EXISTS (SELECT 1 FROM dbo.Branches AS b
                      WHERE b.BranchCode = td.BranchCode);

    /* ---- 8. Open AR items that cannot be aged (NULL/future invoice date) */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 8, 'AR open items with unaged date (NULL/future)', 'WARNING',
           COUNT(*), SUM(Balance)
    FROM dbo.TransactionChargeSales
    WHERE Balance > 0
      AND (TransactionDate IS NULL OR TransactionDate > @AsOfDate);

    /* ---- 9. Open AP items that cannot be aged (NULL/future invoice date) */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 9, 'AP open items with unaged date (NULL/future)', 'WARNING',
           COUNT(*), SUM(Balance)
    FROM dbo.APAccounts
    WHERE Balance > 0
      AND (InvoiceDate IS NULL OR InvoiceDate > @AsOfDate);

    /* ---- 10. Open AR items whose CustomerKey has no match in Customers - */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 10, 'AR open items with unknown CustomerKey', 'WARNING',
           COUNT(*), SUM(t.Balance)
    FROM dbo.TransactionChargeSales AS t
    WHERE t.Balance > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.Customers AS c WHERE c.CustomerKey = t.CustomerKey);

    /* ---- 11. Open AP items whose SupplierID has no match in Supplier ---
       Expected to be materially nonzero today (~49% / ~676M) — that is a
       correct, known finding per the investigation, not a bug in this check. */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 11, 'AP open items with unknown SupplierID', 'WARNING',
           COUNT(*), SUM(a.Balance)
    FROM dbo.APAccounts AS a
    WHERE a.Balance > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.Supplier AS s WHERE s.SupplierID = a.SupplierID);

    /* ---- GL hybrid components shared by checks #12 and #13 -------------
       FIX 2026-09-29 (db-report-engineer, sql/28): #GLCutoffHC is now keyed
       by (BranchCode, AccountCode), not BranchCode alone, and is computed
       from GLSummary's own activity-filtered MAX(PostingDate) directly —
       PostingDateControl is no longer read. See this file's header for the
       full root-cause investigation and confirmed within-branch divergence
       across these four accounts (this proc has no @BranchCodes parameter,
       so company-wide, no branch filter, same as before). */
    CREATE TABLE #GLCutoffHC
    (
        BranchCode  varchar(5)  NOT NULL,
        AccountCode varchar(20) NOT NULL,
        Cutoff      datetime    NULL,
        PRIMARY KEY (BranchCode, AccountCode)
    );

    INSERT INTO #GLCutoffHC (BranchCode, AccountCode, Cutoff)
    SELECT bs.BranchCode, acct.AccountCode,
           (SELECT MAX(g.PostingDate)
            FROM dbo.GLSummary AS g
            WHERE g.BranchCode  = bs.BranchCode
              AND g.AccountCode = acct.AccountCode
              AND (g.Debits <> 0 OR g.Credits <> 0))
    FROM (
        SELECT DISTINCT BranchCode FROM dbo.Branches
        UNION SELECT DISTINCT BranchCode FROM dbo.GLSummary
        UNION SELECT DISTINCT BranchCode FROM dbo.TicketDetails
    ) AS bs
    CROSS JOIN (VALUES ('101030101'), ('20101'), ('20102'), ('20103')) AS acct(AccountCode);

    CREATE TABLE #ARAPOpeningHC (BranchCode varchar(5), AccountCode varchar(20), SignedOpening decimal(18,2));

    INSERT INTO #ARAPOpeningHC (BranchCode, AccountCode, SignedOpening)
    SELECT g.BranchCode, g.AccountCode,
           CAST(CASE coa.Nature WHEN 'D' THEN g.EndingBalance ELSE -g.EndingBalance END AS decimal(18,2))
    FROM (
        SELECT BranchCode, AccountCode, PostingDate, EndingBalance,
               rn = ROW_NUMBER() OVER (PARTITION BY BranchCode, AccountCode ORDER BY PostingDate DESC)
        FROM dbo.GLSummary
        WHERE AccountCode IN ('101030101', '20101', '20102', '20103')
          AND PostingDate < @AsOfEnd
    ) AS g
    INNER JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = g.AccountCode
    WHERE g.rn = 1;

    DECLARE @AROpeningHC decimal(18,2) = ISNULL((SELECT SUM(SignedOpening) FROM #ARAPOpeningHC
                                                  WHERE AccountCode = '101030101'), 0);
    DECLARE @APOpeningHC decimal(18,2) = ISNULL((SELECT SUM(SignedOpening) FROM #ARAPOpeningHC
                                                  WHERE AccountCode IN ('20101', '20102', '20103')), 0);

    DECLARE @ARLiveHC decimal(18,2) = (
        SELECT ISNULL(SUM(CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit
                                           ELSE          td.Credit - td.Debit END), 0)
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        INNER JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
        INNER JOIN dbo.vw_AccountTree AS t ON t.AccountCode = td.AccountCode
        INNER JOIN #GLCutoffHC AS gc ON gc.BranchCode = td.BranchCode AND gc.AccountCode = td.AccountCode
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND coa.AccountType = 'D'
          AND td.TicketDate < @AsOfEnd
          AND (gc.Cutoff IS NULL OR td.TicketDate > gc.Cutoff)
          AND t.AncestorCode = '101030101'
    );

    DECLARE @APLiveHC decimal(18,2) = (
        SELECT ISNULL(SUM(CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit
                                           ELSE          td.Credit - td.Debit END), 0)
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        INNER JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
        INNER JOIN dbo.vw_AccountTree AS t ON t.AccountCode = td.AccountCode
        INNER JOIN #GLCutoffHC AS gc ON gc.BranchCode = td.BranchCode AND gc.AccountCode = td.AccountCode
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND coa.AccountType = 'D'
          AND td.TicketDate < @AsOfEnd
          AND (gc.Cutoff IS NULL OR td.TicketDate > gc.Cutoff)
          AND t.AncestorCode IN ('20101', '20102', '20103')
    );

    /* ---- 12. AR subledger total vs GL control account 101030101 --------
       @ARGL now = GLSummary migration opening (branch-hybrid) + live ticket
       movement after each (branch, account)'s own activity-filtered
       cutover, instead of a single per-branch cutoff.
       Findings = 1 when the gap is nonzero (else 0). ValueAtRisk = the gap. */
    DECLARE @ARSubledger decimal(18,2) = (SELECT ISNULL(SUM(Balance), 0)
                                           FROM dbo.TransactionChargeSales WHERE Balance > 0);
    DECLARE @ARGL decimal(18,2) = ISNULL(@ARLiveHC, 0) + @AROpeningHC;

    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 12, 'AR subledger vs GL 101030101 tie-out gap', 'CRITICAL',
           CASE WHEN @ARSubledger <> @ARGL THEN 1 ELSE 0 END,
           ABS(@ARSubledger - @ARGL);

    /* ---- 13. AP (Trade+Expense) subledger total vs GL control accounts
       20101/20102/20103
       @APSubledger is UNCHANGED from the 2026-09-12 redefinition
       (APAccounts.Balance + ExpenseSummary.Balance — see
       sql/09-apexp-aging.sql for that investigation). @APGL now uses the
       per-(branch,account) activity-filtered cutover — this was the actual
       gap this pass was asked to close; the Trade+Expense subledger
       redefinition is a separate, already-shipped decision, left as-is. */
    DECLARE @APSubledger decimal(18,2) = (SELECT ISNULL(SUM(Balance), 0)
                                           FROM dbo.APAccounts WHERE Balance > 0)
                                        + (SELECT ISNULL(SUM(Balance), 0)
                                           FROM dbo.ExpenseSummary WHERE Balance > 0);
    DECLARE @APGL decimal(18,2) = ISNULL(@APLiveHC, 0) + @APOpeningHC;

    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 13, 'AP (Trade+Expense) subledger vs GL 20101/20102/20103 tie-out gap', 'CRITICAL',
           CASE WHEN @APSubledger <> @APGL THEN 1 ELSE 0 END,
           ABS(@APSubledger - @APGL);

    DROP TABLE #ARAPOpeningHC;
    DROP TABLE #GLCutoffHC;

    /* ---- 14. Standing assertion: AR Balance < 0 should never happen ----- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 14, 'AR items with negative Balance', 'CRITICAL',
           COUNT(*), SUM(ABS(Balance))
    FROM dbo.TransactionChargeSales
    WHERE Balance < 0;

    /* ---- 15. Standing assertion: AP Balance < 0 should never happen ----- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 15, 'AP items with negative Balance', 'CRITICAL',
           COUNT(*), SUM(ABS(Balance))
    FROM dbo.APAccounts
    WHERE Balance < 0;

    /* ---- 16. Open AP-EXP items that cannot be aged (NULL/future date) --- */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 16, 'AP-EXP open items with unaged date (NULL/future)', 'WARNING',
           COUNT(*), SUM(Balance)
    FROM dbo.ExpenseSummary
    WHERE Balance > 0
      AND (ExpenseDate IS NULL OR ExpenseDate > @AsOfDate);

    /* ---- 17. Open AP-EXP items whose SupplierID has no match in Supplier */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 17, 'AP-EXP open items with unknown SupplierID', 'WARNING',
           COUNT(*), SUM(e.Balance)
    FROM dbo.ExpenseSummary AS e
    WHERE e.Balance > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.Supplier AS s WHERE s.SupplierID = e.SupplierID);

    /* ---- 18. Standing assertion: AP-EXP Balance < 0 should never happen - */
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 18, 'AP-EXP items with negative Balance', 'CRITICAL',
           COUNT(*), SUM(ABS(Balance))
    FROM dbo.ExpenseSummary
    WHERE Balance < 0;

    -- Seq is projected so the app can drill down to
    -- sp_rpt_DataHealthCheckDetail(@Seq=...) for the row a user clicks,
    -- without relying on row position matching insertion order.
    SELECT Seq, CheckName, Severity, Findings, ValueAtRisk
    FROM #Result
    ORDER BY Seq;

    DROP TABLE #Result;
END
GO


/* ============================================================================
   3. sp_rpt_Exec_FlowBar — same per-(branch,account) fix, @DateTo-only sig
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
       GLSummary term. See sql/13's header for the ON_HAND blind-spot flag
       (deliberately left unfixed here, out of scope for this pass). ------ */
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
       (branch, account)'s OWN activity-filtered cutover.
       FIX 2026-09-29 (db-report-engineer, sql/28): identical redesign to
       sp_rpt_Exec_Summary — see sql/28's header for the full investigation. */
    CREATE TABLE #GLCutoff
    (
        BranchCode  varchar(5)  NOT NULL,
        AccountCode varchar(20) NOT NULL,
        Cutoff      datetime    NULL,
        PRIMARY KEY (BranchCode, AccountCode)
    );

    INSERT INTO #GLCutoff (BranchCode, AccountCode, Cutoff)
    SELECT bs.BranchCode, acct.AccountCode,
           (SELECT MAX(g.PostingDate)
            FROM dbo.GLSummary AS g
            WHERE g.BranchCode  = bs.BranchCode
              AND g.AccountCode = acct.AccountCode
              AND (g.Debits <> 0 OR g.Credits <> 0))
    FROM (
        SELECT DISTINCT BranchCode FROM dbo.Branches
        UNION SELECT DISTINCT BranchCode FROM dbo.GLSummary
        UNION SELECT DISTINCT BranchCode FROM dbo.TicketDetails
    ) AS bs
    CROSS JOIN (VALUES ('101030101'), ('20101'), ('20102'), ('20103')) AS acct(AccountCode)
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
    INNER JOIN #GLCutoff AS gc ON gc.BranchCode = g.BranchCode AND gc.AccountCode = g.AccountCode
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
    INNER JOIN #GLCutoff AS gc ON gc.BranchCode = td.BranchCode AND gc.AccountCode = td.AccountCode
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND coa.AccountType = 'D'
      AND td.TicketDate < @End
      AND (gc.Cutoff IS NULL OR td.TicketDate > gc.Cutoff)
      AND t.AncestorCode IN ('101030101', '20101', '20102', '20103')
      AND (@FilterBranch = 0 OR td.BranchCode IN (SELECT BranchCode FROM #Branch));

    DECLARE @Receivables money = ISNULL(@ARLive, 0) + @AROpening;
    DECLARE @Payables    money = ISNULL(@APLive, 0) + @APOpening;

    /* ---- Result: same six stages, same columns, explicit CAST on every
       column (Hard Rule #8). NULL for unavailable stages preserved. ------ */
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
   4. sp_rpt_BalanceSheetLiveWithDate — per-(branch,account) cutoff for EVERY
   account, not just AR/AP (broader scope than #1-3 — see header).
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_BalanceSheetLiveWithDate', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_BalanceSheetLiveWithDate;
GO

CREATE PROCEDURE [dbo].[sp_rpt_BalanceSheetLiveWithDate]
    @BranchCode          VARCHAR(5) = NULL,
    @AsOfDate            DATE,
    @IncludeLiveActivity BIT        = 1,   -- 0 = tie-out mode: must match sp_rpt_BalanceSheetWithDate exactly
    @IncludeZeroActivity BIT        = 0    -- 1 = show every BS detail account, including zero/no-activity ones
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#LatestPosting') IS NOT NULL DROP TABLE #LatestPosting;

    -- ── Hybrid posted+live ending balance per account, built ONCE ──────
    -- FIX 2026-09-29 (db-report-engineer, sql/28): replaced the old
    -- BranchScope/GLMaxDate/BranchCutoff chain (COALESCE(PostingDateControl.
    -- LatestPostingDate, MAX(GLSummary.PostingDate)), ONE cutoff per branch
    -- applied to EVERY account) with AccountCutoff, keyed by (BranchCode,
    -- AccountCode) and computed from GLSummary's own activity-filtered
    -- MAX(PostingDate) directly (Debits<>0 OR Credits<>0) — PostingDateControl
    -- is no longer read. Confirmed live before this change that different
    -- accounts within the SAME branch go stale on very different dates (see
    -- sql/28's header) — a single per-branch cutoff silently dropped real
    -- ticket activity for accounts whose true freeze date was earlier than
    -- whatever generic cutoff the branch resolved to. LEFT JOIN (not INNER)
    -- so an account that never had ANY GLSummary row still gets Cutoff =
    -- NULL, falling back to full ticket history, same as before this fix.
    ;WITH AccountCutoff AS
    (
        SELECT g.BranchCode, g.AccountCode, MAX(g.PostingDate) AS Cutoff
        FROM GLSummary g
        WHERE (@BranchCode IS NULL OR g.BranchCode = @BranchCode)
          AND (g.Debits <> 0 OR g.Credits <> 0)
        GROUP BY g.BranchCode, g.AccountCode
    ),
    LatestPerBranch AS
    (
        SELECT
             gs.BranchCode
            ,gs.AccountCode
            ,gs.EndingBalance
            ,ROW_NUMBER() OVER (
                PARTITION BY gs.BranchCode, gs.AccountCode
                ORDER BY gs.PostingDate DESC, gs.SupplementaryNumber DESC
             ) AS rn
        FROM GLSummary gs
        WHERE (@BranchCode IS NULL OR gs.BranchCode = @BranchCode)
          AND gs.PostingDate <= @AsOfDate
    ),
    PostedPerBranch AS
    (
        SELECT BranchCode, AccountCode, EndingBalance
        FROM LatestPerBranch
        WHERE rn = 1
    ),
    LiveActivity AS
    (
        -- Hard Rule #1 (TicketMaster/Status join) preserved from the
        -- original 2026-09-15 fix (sql/11) — unchanged by this pass.
        SELECT
             td.BranchCode
            ,td.AccountCode
            ,SUM(ISNULL(td.Debit,0)) - SUM(ISNULL(td.Credit,0)) AS LiveDelta
        FROM TicketDetails td
        LEFT JOIN AccountCutoff ac ON ac.BranchCode = td.BranchCode AND ac.AccountCode = td.AccountCode
        INNER JOIN TicketMaster tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE @IncludeLiveActivity = 1
          AND (@BranchCode IS NULL OR td.BranchCode = @BranchCode)
          AND tm.Status IN ('POSTED', 'UPDATED')
          AND td.TicketDate >= DATEADD(day, 1, ISNULL(ac.Cutoff, '19000101'))
          AND td.TicketDate <  DATEADD(day, 1, @AsOfDate)
        GROUP BY td.BranchCode, td.AccountCode
    ),
    BranchAccountCombined AS
    (
        SELECT
             COALESCE(pb.BranchCode, la.BranchCode)               AS BranchCode
            ,COALESCE(pb.AccountCode, la.AccountCode)              AS AccountCode
            ,ISNULL(pb.EndingBalance,0) + ISNULL(la.LiveDelta,0)   AS EndingBalance
        FROM PostedPerBranch pb
        FULL OUTER JOIN LiveActivity la
            ON la.BranchCode = pb.BranchCode AND la.AccountCode = pb.AccountCode
    )
    SELECT AccountCode, SUM(EndingBalance) AS EndingBalance
    INTO #LatestPosting
    FROM BranchAccountCombined
    GROUP BY AccountCode;

    -- ── SET 1: Line items ────────────────────────────────────────────
    ;WITH BSBase AS
    (
        SELECT
             coa.AccountCode
            ,coa.Description AS AccountDescription
            ,CASE
                WHEN coa.AccountCode LIKE '101%' OR coa.AccountCode LIKE '102%' OR coa.AccountCode LIKE '103%'
                    THEN CAST(ISNULL(lp.EndingBalance,0)  AS DECIMAL(19,2))
                ELSE CAST(-ISNULL(lp.EndingBalance,0) AS DECIMAL(19,2))
             END AS Amount
            ,CAST(ISNULL(lp.EndingBalance,0) AS DECIMAL(19,2)) AS RawEndingBalance
        FROM ChartOfAccounts coa
        LEFT JOIN #LatestPosting lp ON lp.AccountCode = coa.AccountCode
        WHERE coa.AccountType    = 'D'
          AND coa.YearEndIndicator = 'BS'
          AND (@IncludeZeroActivity = 1 OR ISNULL(lp.EndingBalance,0) <> 0)
    ),
    CurrentEarnings AS
    (
        SELECT
             'CURRENT_EARNINGS'        AS AccountCode
            ,'Current Period Earnings' AS AccountDescription
            ,CAST(-SUM(ISNULL(lp.EndingBalance, 0)) AS DECIMAL(19,2)) AS Amount
            ,CAST( SUM(ISNULL(lp.EndingBalance, 0)) AS DECIMAL(19,2)) AS RawEndingBalance
        FROM #LatestPosting lp
        INNER JOIN ChartOfAccounts coa ON coa.AccountCode = lp.AccountCode
        WHERE coa.AccountType    = 'D'
          AND coa.YearEndIndicator = 'IS'
    )
    SELECT * FROM (
        SELECT * FROM BSBase
        UNION ALL
        SELECT * FROM CurrentEarnings WHERE Amount <> 0
    ) x
    ORDER BY AccountCode;

    -- ── SET 2: Section subtotals + balance check (unchanged) ─────────
    ;WITH BSBase AS
    (
        SELECT
            CASE
                WHEN coa.AccountCode LIKE '101%'  THEN '1-Current Assets'
                WHEN coa.AccountCode LIKE '102%'  THEN '2-Non-Current Assets'
                WHEN coa.AccountCode LIKE '103%'  THEN '2-Non-Current Assets'
                WHEN coa.AccountCode = '20202'    THEN '3-Current Liabilities'
                WHEN coa.AccountCode LIKE '201%'  THEN '3-Current Liabilities'
                WHEN coa.AccountCode LIKE '202%'  THEN '4-Non-Current Liabilities'
                WHEN coa.AccountCode LIKE '203%'  THEN '4-Non-Current Liabilities'
                WHEN coa.AccountCode LIKE '3%'    THEN '5-Equity'
                ELSE '9-Other'
            END AS BSSection
            ,CASE
                WHEN coa.AccountCode LIKE '101%' OR coa.AccountCode LIKE '102%' OR coa.AccountCode LIKE '103%'
                    THEN CAST(lp.EndingBalance  AS DECIMAL(19,2))
                ELSE CAST(-lp.EndingBalance AS DECIMAL(19,2))
             END AS Amount
        FROM #LatestPosting lp
        INNER JOIN ChartOfAccounts coa ON coa.AccountCode = lp.AccountCode
        WHERE coa.AccountType = 'D' AND coa.YearEndIndicator = 'BS'
    ),
    CurrentEarnings AS
    (
        SELECT
             '5-Equity' AS BSSection
            ,CAST(-SUM(ISNULL(lp.EndingBalance,0)) AS DECIMAL(19,2)) AS Amount
        FROM #LatestPosting lp
        INNER JOIN ChartOfAccounts coa ON coa.AccountCode = lp.AccountCode
        WHERE coa.AccountType = 'D' AND coa.YearEndIndicator = 'IS'
    ),
    Combined AS
    (
        SELECT BSSection, Amount FROM BSBase
        UNION ALL
        SELECT BSSection, Amount FROM CurrentEarnings WHERE Amount <> 0
    ),
    AllSections AS
    (
        SELECT BSSection FROM (VALUES
            ('1-Current Assets'), ('2-Non-Current Assets'),
            ('3-Current Liabilities'), ('4-Non-Current Liabilities'),
            ('5-Equity')
        ) AS s(BSSection)
    ),
    SectionTotals AS
    (
        SELECT s.BSSection, CAST(ISNULL(SUM(c.Amount),0) AS DECIMAL(19,2)) AS SectionTotal
        FROM AllSections s
        LEFT JOIN Combined c ON c.BSSection = s.BSSection
        GROUP BY s.BSSection

        UNION ALL

        SELECT c.BSSection, CAST(SUM(c.Amount) AS DECIMAL(19,2)) AS SectionTotal
        FROM Combined c
        WHERE c.BSSection NOT IN (SELECT BSSection FROM AllSections)
        GROUP BY c.BSSection
    ),
    GrandTotals AS
    (
        SELECT
             CAST(SUM(CASE WHEN BSSection LIKE '1%' OR BSSection = '2-Non-Current Assets'
                           THEN SectionTotal ELSE 0 END) AS DECIMAL(19,2)) AS TotalAssets
            ,CAST(SUM(CASE WHEN BSSection LIKE '3%' OR BSSection LIKE '4%'
                           THEN SectionTotal ELSE 0 END) AS DECIMAL(19,2)) AS TotalLiabilities
            ,CAST(SUM(CASE WHEN BSSection LIKE '5%'
                           THEN SectionTotal ELSE 0 END) AS DECIMAL(19,2)) AS TotalEquity
        FROM SectionTotals
    )
    SELECT
         st.BSSection
        ,st.SectionTotal
        ,gt.TotalAssets
        ,gt.TotalLiabilities
        ,gt.TotalEquity
        ,@AsOfDate                    AS AsOfDate
        ,ISNULL(@BranchCode, 'ALL')   AS BranchCode
    FROM SectionTotals st
    CROSS JOIN GrandTotals gt
    ORDER BY st.BSSection;

    DROP TABLE IF EXISTS #LatestPosting;
END;
GO


/* ============================================================================
   5. sp_rpt_IncomeStatementLiveWithDate — same AccountCutoff redesign
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_IncomeStatementLiveWithDate', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_IncomeStatementLiveWithDate;
GO

CREATE PROCEDURE [dbo].[sp_rpt_IncomeStatementLiveWithDate]
    @BranchCode          VARCHAR(5) = NULL,
    @DateFrom            DATE,
    @DateTo              DATE,
    @IncludeLiveActivity BIT        = 1,   -- 0 = tie-out mode: must match sp_rpt_IncomeStatementWithDate exactly (single-branch only)
    @IncludeZeroActivity BIT        = 0    -- 1 = show every IS detail account, including zero/no-activity ones
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#CombinedActivity') IS NOT NULL DROP TABLE #CombinedActivity;

    -- ── Hybrid posted+live period activity per account, built ONCE,
    --    consolidated across every in-scope branch ─────────────────────
    -- FIX 2026-09-29 (db-report-engineer, sql/28): same AccountCutoff
    -- redesign as sp_rpt_BalanceSheetLiveWithDate — see that proc's header
    -- comment and sql/28's file header for the full investigation.
    ;WITH AccountCutoff AS
    (
        SELECT g.BranchCode, g.AccountCode, MAX(g.PostingDate) AS Cutoff
        FROM GLSummary g
        WHERE (@BranchCode IS NULL OR g.BranchCode = @BranchCode)
          AND (g.Debits <> 0 OR g.Credits <> 0)
        GROUP BY g.BranchCode, g.AccountCode
    ),
    PostedActivity AS
    (
        SELECT
             gs.AccountCode
            ,SUM(gs.Debits)       AS PeriodDebits
            ,SUM(ABS(gs.Credits)) AS PeriodCredits
        FROM GLSummary gs
        WHERE (@BranchCode IS NULL OR gs.BranchCode = @BranchCode)
          -- Hard Rule #4 (>= / < DATEADD(DAY,1,...)) preserved from sql/11.
          AND gs.PostingDate >= @DateFrom
          AND gs.PostingDate <  DATEADD(DAY, 1, @DateTo)
        GROUP BY gs.AccountCode
    ),
    LiveActivity AS
    (
        -- Live window per (branch, account) starts the later of (that
        -- pair's OWN activity-filtered cutoff + 1 day) and @DateFrom.
        -- Hard Rule #1 (TicketMaster/Status join) preserved from sql/11.
        SELECT
             td.AccountCode
            ,SUM(ISNULL(td.Debit,0))  AS PeriodDebits
            ,SUM(ISNULL(td.Credit,0)) AS PeriodCredits
        FROM TicketDetails td
        LEFT JOIN AccountCutoff ac ON ac.BranchCode = td.BranchCode AND ac.AccountCode = td.AccountCode
        INNER JOIN TicketMaster tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE @IncludeLiveActivity = 1
          AND (@BranchCode IS NULL OR td.BranchCode = @BranchCode)
          AND tm.Status IN ('POSTED', 'UPDATED')
          AND td.TicketDate >= GREATEST(DATEADD(day, 1, ISNULL(ac.Cutoff, '19000101')), @DateFrom)
          AND td.TicketDate <  DATEADD(day, 1, @DateTo)
        GROUP BY td.AccountCode
    )
    SELECT
         COALESCE(pa.AccountCode, la.AccountCode)                   AS AccountCode
        ,ISNULL(pa.PeriodDebits,0)     + ISNULL(la.PeriodDebits,0)  AS PeriodDebits
        ,ISNULL(pa.PeriodCredits,0)    + ISNULL(la.PeriodCredits,0) AS PeriodCredits
    INTO #CombinedActivity
    FROM PostedActivity pa
    FULL OUTER JOIN LiveActivity la ON la.AccountCode = pa.AccountCode;

    -- ── SET 1: Line items ────────────────────────────────────────────
    SELECT
         coa.AccountCode
        ,coa.Description AS AccountDescription
        ,coa.LevelNumber
        ,coa.Nature
        ,CASE
            WHEN LEFT(coa.AccountCode,1) = '4' THEN '1-Revenue'
            WHEN LEFT(coa.AccountCode,1) = '5' THEN '2-Cost of Goods Sold'
            WHEN LEFT(coa.AccountCode,1) = '6' THEN '3-Operating Expenses'
            ELSE                                     '9-Other'
         END AS ISSection
        ,CASE
            WHEN coa.AccountCode LIKE '601%' THEN '3A-Employee Benefits'
            WHEN coa.AccountCode LIKE '602%' THEN '3B-Depreciation'
            WHEN coa.AccountCode LIKE '603%' THEN '3C-Selling & Admin'
            WHEN LEFT(coa.AccountCode,1) = '6' THEN '3D-Other Expenses'
            ELSE NULL
         END AS ExpenseSubSection
        ,CAST(ISNULL(ca.PeriodDebits,0)  AS DECIMAL(19,2)) AS PeriodDebits
        ,CAST(ISNULL(ca.PeriodCredits,0) AS DECIMAL(19,2)) AS PeriodCredits
        ,CAST(
            CASE coa.Nature
                WHEN 'C' THEN ISNULL(ca.PeriodCredits,0) - ISNULL(ca.PeriodDebits,0)
                WHEN 'D' THEN ISNULL(ca.PeriodDebits,0)  - ISNULL(ca.PeriodCredits,0)
            END
         AS DECIMAL(19,2)) AS NetAmount
        ,CASE
            WHEN LEFT(coa.AccountCode,1) = '5'
             AND coa.Nature = 'C'
            THEN 1 ELSE 0
         END AS IsContraCOGS
        ,@DateFrom  AS PeriodFrom
        ,@DateTo    AS PeriodTo
    FROM ChartOfAccounts coa
    LEFT JOIN #CombinedActivity ca ON ca.AccountCode = coa.AccountCode
    WHERE coa.AccountType      = 'D'
      AND coa.YearEndIndicator = 'IS'
      AND (@IncludeZeroActivity = 1 OR ISNULL(ca.PeriodDebits,0) <> 0 OR ISNULL(ca.PeriodCredits,0) <> 0)
    ORDER BY ISSection, coa.AccountCode;

    -- ── SET 2: P&L Summary (unchanged math) ───────────────────────────
    SELECT
         CAST(ISNULL(SUM(
            CASE WHEN LEFT(coa.AccountCode,1) = '4'
             THEN ca.PeriodCredits - ca.PeriodDebits
             ELSE 0 END
         ),0) AS DECIMAL(19,2))                                AS TotalRevenue

        ,CAST(ISNULL(SUM(
            CASE
                WHEN LEFT(coa.AccountCode,1) = '5' AND coa.Nature = 'D'
                THEN ca.PeriodDebits - ca.PeriodCredits
                WHEN LEFT(coa.AccountCode,1) = '5' AND coa.Nature = 'C'
                THEN -(ca.PeriodCredits - ca.PeriodDebits)
                ELSE 0
            END
         ),0) AS DECIMAL(19,2))                                AS TotalCOGS

        ,CAST(ISNULL(
            SUM(CASE WHEN LEFT(coa.AccountCode,1)='4'
                 THEN ca.PeriodCredits - ca.PeriodDebits ELSE 0 END)
           -SUM(CASE WHEN LEFT(coa.AccountCode,1)='5' AND coa.Nature='D'
                 THEN ca.PeriodDebits - ca.PeriodCredits ELSE 0 END)
           +SUM(CASE WHEN LEFT(coa.AccountCode,1)='5' AND coa.Nature='C'
                 THEN ca.PeriodCredits - ca.PeriodDebits ELSE 0 END)
         ,0) AS DECIMAL(19,2))                                  AS GrossProfit

        ,CAST(ISNULL(SUM(
            CASE WHEN LEFT(coa.AccountCode,1) = '6'
             THEN ca.PeriodDebits - ca.PeriodCredits
             ELSE 0 END
         ),0) AS DECIMAL(19,2))                                AS TotalExpenses

        ,CAST(ISNULL(
            SUM(CASE WHEN LEFT(coa.AccountCode,1)='4'
                      AND coa.AccountCode NOT IN ('403','404')
                 THEN ca.PeriodCredits - ca.PeriodDebits ELSE 0 END)
           -SUM(CASE WHEN LEFT(coa.AccountCode,1)='5' AND coa.Nature='D'
                 THEN ca.PeriodDebits - ca.PeriodCredits ELSE 0 END)
           +SUM(CASE WHEN LEFT(coa.AccountCode,1)='5' AND coa.Nature='C'
                 THEN ca.PeriodCredits - ca.PeriodDebits ELSE 0 END)
           -SUM(CASE WHEN LEFT(coa.AccountCode,1)='6'
                 THEN ca.PeriodDebits - ca.PeriodCredits ELSE 0 END)
         ,0) AS DECIMAL(19,2))                                  AS OperatingIncome

        ,CAST(ISNULL(SUM(
            CASE WHEN coa.AccountCode IN ('403','404')
             THEN ca.PeriodCredits - ca.PeriodDebits
             ELSE 0 END
         ),0) AS DECIMAL(19,2))                                AS OtherIncome

        ,CAST(ISNULL(
            SUM(CASE WHEN LEFT(coa.AccountCode,1)='4'
                 THEN ca.PeriodCredits - ca.PeriodDebits ELSE 0 END)
           -SUM(CASE WHEN LEFT(coa.AccountCode,1)='5' AND coa.Nature='D'
                 THEN ca.PeriodDebits - ca.PeriodCredits ELSE 0 END)
           +SUM(CASE WHEN LEFT(coa.AccountCode,1)='5' AND coa.Nature='C'
                 THEN ca.PeriodCredits - ca.PeriodDebits ELSE 0 END)
           -SUM(CASE WHEN LEFT(coa.AccountCode,1)='6'
                 THEN ca.PeriodDebits - ca.PeriodCredits ELSE 0 END)
         ,0) AS DECIMAL(19,2))                                  AS NetIncome

        ,@DateFrom                   AS PeriodFrom
        ,@DateTo                     AS PeriodTo
        ,ISNULL(@BranchCode, 'ALL')  AS BranchCode
    FROM #CombinedActivity ca
    INNER JOIN ChartOfAccounts coa ON coa.AccountCode = ca.AccountCode
    WHERE coa.AccountType      = 'D'
      AND coa.YearEndIndicator = 'IS';

    DROP TABLE IF EXISTS #CombinedActivity;
END;
GO


/* ============================================================================
   SMOKE TEST / BEFORE-AFTER VERIFICATION
   (all values below were captured live on COREX001 immediately before and
    after this script ran, same day — 2026-09-29. These are ACTUAL EXECUTED
    results, not projections — re-run the EXEC pairs below to reproduce.)
============================================================================ */
/*
-- ============================================================================
-- 1. sp_rpt_Exec_Summary — Aug 2026, company-wide
-- ============================================================================
EXEC dbo.sp_rpt_Exec_Summary_OLD_20260929 @DateFrom = '2026-08-01', @DateTo = '2026-08-31';
EXEC dbo.sp_rpt_Exec_Summary              @DateFrom = '2026-08-01', @DateTo = '2026-08-31';

BEFORE: ReceivablesTrade = 247,549,114.34   PayablesTrade = 807,494,607.70
AFTER:  ReceivablesTrade = 275,559,481.72   PayablesTrade = 872,624,045.07
DELTA:  +28,010,367.38 (+11.3%)             +65,129,437.37 (+8.1%)

AR matches the task brief's independently-verified target (~275.6M) almost
exactly (within ~$820, i.e. ticket-timing noise). AP does NOT match the
brief's ~836.4M target — see "AP DIVERGENCE FROM TASK BRIEF" below, a
material, investigated, and explained difference, not an error swept under
the rug.
No other column in this result set changed (NetSales, COGS, CashPosition,
InventoryOnHand/InTransit all byte-identical before/after — confirmed by
diffing the full row, not just AR/AP).

-- ============================================================================
-- 2. sp_rpt_DataHealthCheck — Aug 2026, all 18 checks
-- ============================================================================
EXEC dbo.sp_rpt_DataHealthCheck_OLD_20260929 @DateFrom = '2026-08-01', @DateTo = '2026-08-31';
EXEC dbo.sp_rpt_DataHealthCheck              @DateFrom = '2026-08-01', @DateTo = '2026-08-31';

Check #12 (AR tie-out gap):  BEFORE ValueAtRisk = 14,282,170.54
                             AFTER  ValueAtRisk = 13,728,196.84
Check #13 (AP tie-out gap):  BEFORE ValueAtRisk = 79,976,602.94
                             AFTER  ValueAtRisk = 14,847,165.57
Check #12 matches the task brief's target (~13.7M) almost exactly. Check
#13 does NOT match the brief's ~51.0M target (actual is 14.85M, i.e. the
gap closed MUCH more than expected) — same root cause as the AP divergence
above; see below. Findings flags unchanged (both still = 1, CRITICAL, as
expected — a real, confirmed AR/AP subledger-vs-GL gap remains; this fix
corrects the reported GAP AMOUNT, it does not eliminate the gap).
All other 16 checks (1-11, 14-18) confirmed BYTE-IDENTICAL before/after by
diffing every row, not just #12/#13.

-- ============================================================================
-- AP DIVERGENCE FROM TASK BRIEF — INVESTIGATED, NOT GLOSSED OVER
-- ============================================================================
The brief's pre-stated targets (~836.4M Payables, ~51.0M check-#13 gap) are
internally consistent WITH EACH OTHER (both imply an assumed @APGL of
~836.4M — confirmed algebraically: the fixed AP subledger total this
session found is 887,471,210.29 [= 14,847,165.57 (this fix's #13 gap) +
872,624,045.07 (this fix's @APGL), independently re-derivable as
836.4M + 51.0M from the brief's own two numbers], so both of the brief's
numbers point at the SAME underlying @APGL assumption of ~836.4M). This
fix instead produces @APGL = 872,624,045.07 — a real, ~36.2M difference in
the same direction for both figures, not two unrelated discrepancies.

Root-caused by breaking the AP delta down per account (company-wide,
Aug-31 as-of, this fix's own live-window methodology):
    101030101 (AR, for comparison) opening 247,549,114.34 + live 28,010,367.38
    20101 (AP-Trade)    opening 708,235,084.02 + live 65,151,520.70  <- ALL of it
    20102 (AP-Others)   opening      34,918.28 + live    -22,083.33
    20103 (AP-Accrued)  opening  99,224,605.40 + live          0.00 (never
                                                    frozen at ANY branch as
                                                    of this snapshot — its
                                                    activity-filtered cutoff
                                                    equals the naive one
                                                    everywhere, a genuine
                                                    no-op)
Essentially the ENTIRE ~65.1M AP delta traces to account 20101 (AP-Trade)
alone, and within that, disproportionately to BranchCode 888, whose 20101
was found frozen since 2026-07-01 (see this file's header) — i.e. nearly
two months of real, posted AP-Trade activity at Head Office was being
silently dropped by the old bug, far longer than the ~6-week freeze window
AR experienced. This is plausible given 20101 is the highest-volume trade
payables account and 888 (HO) is the highest-volume branch.

Explicitly tested and RULED OUT the hypothesis that a coarser, non-per-
account fix (single per-branch cutoff = MAX(PostingDate) across all of
101030101/20101/20102/20103's GLSummary rows combined, still with the
activity filter) might explain the brief's ~836.4M: that coarser version
was computed live and reproduces the ORIGINAL BUGGY 807,494,607.70 exactly,
company-wide (because in every branch at least one of these four accounts,
typically 20103, is NOT frozen, so a combined per-branch MAX collapses back
to the naive/PostingDateControl-poisoned 8/31 date — i.e. that coarser
approach is not a partial fix, it is NO fix at all). This rules out "the
brief used a per-branch-not-per-account version" as the explanation.

Best remaining hypothesis (not confirmable without the brief author's own
working notes, flagged as such): the brief's ~836.4M/~51.0M figures may
have been estimated by applying a single company-wide-style correction of
similar magnitude to AR's own ~28M delta, without independently discovering
20101's much longer, branch-888-specific freeze window — i.e. the brief's
own pre-computed AP number may itself have been undercounting this specific
account's exposure. This is flagged prominently for accounting-reviewer:
the per-(branch,account) fix applied here is the one the task explicitly
required after finding per-branch cutoffs invalid, is internally consistent
across all three procs that share this logic (Exec_Summary, DataHealthCheck,
FlowBar, BalanceSheetLiveWithDate all independently converge on the exact
same 872,624,045.07 AP figure — cross-checked below), and is not adjusted
to chase the brief's pre-stated number.

-- ============================================================================
-- 3. sp_rpt_Exec_FlowBar — as of 2026-08-31, company-wide
-- ============================================================================
EXEC dbo.sp_rpt_Exec_FlowBar_OLD_20260929 @DateTo = '2026-08-31';
EXEC dbo.sp_rpt_Exec_FlowBar              @DateTo = '2026-08-31';

BEFORE: RECEIVABLES = 247,549,114.34   PAYABLES = 807,494,607.70
AFTER:  RECEIVABLES = 275,559,481.72   PAYABLES = 872,624,045.07
Identical to sp_rpt_Exec_Summary's deltas (expected — same accounts, same
method, same as-of date; confirms cross-proc consistency). OPEN_PO/
IN_TRANSIT/ON_HAND/OPEN_ORDER stages unchanged (IN_TRANSIT = 15,908,339.90,
ON_HAND = -20,005,155.21, byte-identical before/after — these stages have
no GLSummary term and were never touched).

-- ============================================================================
-- 4. sp_rpt_BalanceSheetLiveWithDate — branch 888 and ALL, AsOf 2026-08-31
-- ============================================================================
EXEC dbo.sp_rpt_BalanceSheetLiveWithDate_OLD_20260929 @BranchCode='888', @AsOfDate='2026-08-31', @IncludeLiveActivity=1, @IncludeZeroActivity=0;
EXEC dbo.sp_rpt_BalanceSheetLiveWithDate              @BranchCode='888', @AsOfDate='2026-08-31', @IncludeLiveActivity=1, @IncludeZeroActivity=0;
EXEC dbo.sp_rpt_BalanceSheetLiveWithDate_OLD_20260929 @BranchCode=NULL,  @AsOfDate='2026-08-31', @IncludeLiveActivity=1, @IncludeZeroActivity=0;
EXEC dbo.sp_rpt_BalanceSheetLiveWithDate              @BranchCode=NULL,  @AsOfDate='2026-08-31', @IncludeLiveActivity=1, @IncludeZeroActivity=0;

ALL branches, SET 1 (AR/AP lines, matches #1/#3 exactly — cross-proc
consistency confirmed):
  101030101 AR-TRADE      247,549,114.34 -> 275,559,481.72  (+28,010,367.38)
  20101 AP-TRADE          708,235,084.02 -> 773,386,604.72  (+65,151,520.70)
  20102 AP-OTHERS              34,918.28 ->      12,834.95  (-22,083.33)
  20103 ACCRUED EXP PAYABLE99,224,605.40 -> 99,224,605.40   (unchanged, as
                                                                expected)
  TotalAssets       1,561,590,448.74 -> 1,642,687,541.03  (+81,097,092.29)
  TotalLiabilities    919,499,461.54 ->   984,702,157.58  (+65,202,696.04)
  TotalEquity          642,090,987.20 ->   644,209,243.60  (+2,118,256.40,
    driven entirely by CURRENT_EARNINGS improving — this exactly matches
    the NetIncome swing independently found in sp_rpt_IncomeStatementLive-
    WithDate below, a strong internal-consistency check that the fix is
    mechanically correct across both procs.)

MAJOR ADDITIONAL FINDING — GOES WELL BEYOND THE AR/AP SCOPE THE TASK BRIEF
DESCRIBED FOR THIS PROC. Branch 888 SET 1 went from 66 rows to 72 rows: six
previously-INVISIBLE accounts now appear (101020106, 101020110, 101030204,
101030208, 101040101, 101040102, plus 20115 company-wide). Investigated
live, not assumed: EVERY one of these has ZERO rows in GLSummary for branch
888 (confirmed via direct query), yet has real, POSTED TicketDetails
activity in August 2026 (e.g. 101040102 "INVENTORY IN TRANSIT - VAT EXEMPT"
has 15 posted ticket rows totaling 15,858,339.90 debit). Root cause: the
OLD proc's single per-branch generic cutoff (wrongly resolved to 8/31, the
same PostingDateControl date, for every branch) collapsed the "live" ticket
window to EMPTY for EVERY account in that branch — including accounts that
never had any GLSummary presence at all and should have had their FULL
ticket history counted as live (exactly the pre-existing "branch never had
a GLSummary row = 0 opening, full history" fallback already established by
sql/12, just never extended to work per-account within a branch that DOES
have GLSummary rows for OTHER accounts). This means the old bug was not
just "AR/AP understated" for this proc — entire balance-sheet line items
were silently disappearing from a "live" report whenever an account had no
GLSummary migration history, which will systematically recur for any newer
account added after the ERP's GLSummary migration cutover. This is the
FIRST independent quantification of this proc's exposure (the task brief
flagged it only as "pattern found, impact not yet quantified") and the
finding is materially larger in scope than anticipated.

-- ============================================================================
-- 5. sp_rpt_IncomeStatementLiveWithDate — branch 888 and ALL, Aug 2026
-- ============================================================================
EXEC dbo.sp_rpt_IncomeStatementLiveWithDate_OLD_20260929 @BranchCode='888', @DateFrom='2026-08-01', @DateTo='2026-08-31', @IncludeLiveActivity=1;
EXEC dbo.sp_rpt_IncomeStatementLiveWithDate              @BranchCode='888', @DateFrom='2026-08-01', @DateTo='2026-08-31', @IncludeLiveActivity=1;
EXEC dbo.sp_rpt_IncomeStatementLiveWithDate_OLD_20260929 @BranchCode=NULL,  @DateFrom='2026-08-01', @DateTo='2026-08-31', @IncludeLiveActivity=1;
EXEC dbo.sp_rpt_IncomeStatementLiveWithDate              @BranchCode=NULL,  @DateFrom='2026-08-01', @DateTo='2026-08-31', @IncludeLiveActivity=1;

*** THIS RESULT CONTRADICTS AN EARLIER DRAFT OF THIS COMMENT BLOCK THAT
CLAIMED "ZERO IMPACT" BASED ON AN UNVERIFIED ASSUMPTION (that AR/AP-only
accounts were the sole exposure). That assumption was WRONG and has been
corrected here after actually running the EXEC pairs above — see the
db-report-engineer's handoff note for the same self-correction. ***

ALL branches, SET 2 (P&L summary):
  BEFORE: TotalRevenue 83,860,115.34 | TotalCOGS 100,906,611.63 |
          GrossProfit -17,046,496.29 | TotalExpenses 2,658,275.15 |
          OperatingIncome -19,747,105.16 | OtherIncome 42,333.72 |
          NetIncome -19,704,771.44
  AFTER:  TotalRevenue 130,845,379.95 | TotalCOGS 142,771,836.00 |
          GrossProfit -11,926,456.05 | TotalExpenses 5,660,058.99 |
          OperatingIncome -17,751,548.93 | OtherIncome 165,033.89 |
          NetIncome -17,586,515.04
  DELTA:  Revenue +46,985,264.61 (+56.0%) | COGS +41,865,224.37 (+41.5%) |
          GrossProfit improved +5,120,040.24 | Expenses +3,001,783.84
          (+112.9%) | NetIncome improved +2,118,256.40 (matches the
          TotalEquity/CURRENT_EARNINGS delta found in #4 above exactly —
          confirms mechanical correctness).
  Row count: 36 -> 51 IS accounts now show activity (previously invisible
  accounts, same root cause as #4).

Branch 888, SET 2:
  BEFORE: TotalRevenue 15,133,776.69 | TotalCOGS 21,174,789.76 |
          NetIncome -7,701,146.61
  AFTER:  TotalRevenue 33,681,808.34 | TotalCOGS 37,317,058.73 |
          NetIncome -6,508,421.37
  DELTA:  Revenue +18,548,031.65 (+122.6%) | COGS +16,142,268.97 (+76.2%) |
          NetIncome improved +1,192,725.24

ROOT CAUSE, CONFIRMED LIVE (not assumed): revenue/COGS accounts (e.g. 401
SALES-VAT EXEMPT) turned out to have the SAME per-branch freeze pattern as
AR (401 is debited/credited by the identical sales tickets that hit AR —
confirmed: branch-by-branch activity-filtered cutoffs for account 401 match
almost exactly the cutoffs found for 101030101 in this file's header, e.g.
branch 888 = 2026-08-12). The old bug's single per-branch generic cutoff
being wrongly stuck at 8/31 collapsed the live ticket window to empty for
EVERY account company-wide whenever @DateTo also fell on/near 8/31 —
GLSummary's OWN recorded (frozen-so-mostly-zero) rows for these accounts
were the ONLY contribution the old proc counted, silently dropping weeks of
real posted sales/COGS activity from what is meant to be a "live" income
statement. sp_rpt_IncomeStatementLiveWithDate's exposure to this bug is
THE SAME MAGNITUDE OF PROBLEM as the balance-sheet proc's, not a
separately-scoped, lesser concern — this correction is the largest dollar
swing found in this entire fix pass and needs urgent accounting-reviewer
attention given its effect on reported Net Sales, COGS, and Net Income.

-- ============================================================================
-- CROSS-CHECK: nothing else moved unexpectedly, everything that DID move
-- is accounted for above
-- ============================================================================
sp_rpt_DataHealthCheck (all 18 rows) and sp_rpt_Exec_Summary (all 19
columns) diffed line-by-line, before vs after: only checks #12/#13's
ValueAtRisk (not Findings) and Exec_Summary's ReceivablesTrade/
PayablesTrade columns changed; all else byte-identical. For
sp_rpt_BalanceSheetLiveWithDate / sp_rpt_IncomeStatementLiveWithDate, EVERY
changed line item was traced to either (a) a confirmed per-(branch,account)
GLSummary freeze date earlier than the old bogus branch-wide 8/31 cutoff,
or (b) an account with zero GLSummary presence whose full ticket history
was previously being wrongly suppressed entirely — no unexplained deltas
remain. Cash accounts and other accounts whose OWN GLSummary rows are not
frozen in this window are confirmed byte-identical before/after (e.g. most
101020xxx cash accounts at branch 888) — the fix is fully data-driven, not
a blanket shift.
*/
