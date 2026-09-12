/* ============================================================================
   FIX: sp_rpt_BalanceSheetLiveWithDate / sp_rpt_IncomeStatementLiveWithDate
   Live-leg Status leak + BETWEEN date-range violation.

   BUG (confirmed live in CORECSERP_002_DEV before this fix)
   -----------------------------------------------------------------------
   Both procs' "live" leg reads dbo.TicketDetails directly for ticket
   activity dated after each branch's last GL-Posting cutoff (see the
   PostingDateControl / MAX(GLSummary.PostingDate) BranchCutoff CTE), then
   UNIONs/adds it to the posted dbo.GLSummary snapshot.

   That live leg never joined dbo.TicketMaster and never filtered
   Status IN ('POSTED','UPDATED') -- TicketDetails carries no Status column
   of its own (confirmed via INFORMATION_SCHEMA.COLUMNS: TicketDetails has
   TicketDate, SupplementaryNumber, BranchCode, ReferenceKey, TicketNumber,
   ReferenceNumber, AccountCode, Debit, Credit, CostCenter, Particulars --
   no Status). So unposted, draft, or REVERSED tickets leaked straight into
   the "live" figures. Hard Rule #1 violation.

   Confirmed real instance (before this fix): TicketNumber 5194, Branch
   888, dated 2026-09-10, Status REVERSED, Particulars
   'REVERSAL: OR-OVERPAY ENTRY':
       101020111 (CASH IN BANK - PNB PESO)      credit 9,049.60
       101030101 (ACCOUNTS RECEIVABLE - TRADE)  debit  8,179.20
       404       (OTHER INCOME, IS account)     debit    870.40
   These three lines were included in sp_rpt_BalanceSheetLiveWithDate's
   branch-888 output for any @AsOfDate >= 2026-09-10 (branch 888's GL
   cutoff is 2026-07-31, so 2026-09-10 falls inside the live window).

   FIX
   -----------------------------------------------------------------------
   In each proc's LiveActivity CTE, join TicketMaster on the same natural
   key used everywhere else in this codebase (TicketDate +
   SupplementaryNumber + BranchCode + TicketNumber -- see the Position /
   Movement CTEs in sql/01-exec-overview-data-layer.sql) and filter
   WHERE tm.Status IN ('POSTED','UPDATED'). Nothing else in the live-leg
   logic (cutoff detection, union with GLSummary, branch/account grouping)
   is touched.

   SECOND FIX (IS proc only, same CTE area)
   -----------------------------------------------------------------------
   sp_rpt_IncomeStatementLiveWithDate's PostedActivity CTE used
   `gs.PostingDate BETWEEN @DateFrom AND @DateTo` -- a Hard Rule #4
   violation. Currently harmless only because every GLSummary.PostingDate
   in this DB is midnight (confirmed: 0 of 26,195 rows have a non-midnight
   time), but fragile. Changed to the house convention:
   `>= @DateFrom AND < DATEADD(DAY,1,@DateTo)`. Zero behavioral change
   today; removes a latent risk.

   SCOPE
   -----------------------------------------------------------------------
   Only the two fixes above. No other refactor of either proc.
============================================================================ */


/* ============================================================================
   1. sp_rpt_BalanceSheetLiveWithDate
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
    -- FIX (sp-reviewer): derive branch scope from every table that could
    -- carry a BranchCode, not just Branches -- a branch present in
    -- GLSummary/TicketDetails but missing/renamed in Branches must still
    -- get a cutoff, or its live activity is silently dropped while its
    -- posted balance (which doesn't depend on Branches) still shows up.
    ;WITH BranchScope AS
    (
        SELECT DISTINCT BranchCode FROM (
            SELECT BranchCode FROM Branches
            UNION
            SELECT BranchCode FROM GLSummary
            UNION
            SELECT BranchCode FROM TicketDetails
        ) allBranches
        WHERE (@BranchCode IS NULL OR BranchCode = @BranchCode)
    ),
    GLMaxDate AS
    (
        SELECT BranchCode, MAX(PostingDate) AS MaxPostingDate
        FROM GLSummary
        GROUP BY BranchCode
    ),
    BranchCutoff AS
    (
        SELECT
             bs.BranchCode
            ,COALESCE(pdc.LatestPostingDate, gmd.MaxPostingDate) AS Cutoff
        FROM BranchScope bs
        LEFT JOIN PostingDateControl pdc ON pdc.BranchCode = bs.BranchCode
        LEFT JOIN GLMaxDate          gmd ON gmd.BranchCode = bs.BranchCode
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
        -- FIX (db-report-engineer): TicketDetails carries no Status of its
        -- own. Join TicketMaster on its natural key (TicketDate +
        -- SupplementaryNumber + BranchCode + TicketNumber, same pattern as
        -- Position/Movement in sql/01-exec-overview-data-layer.sql) and
        -- require POSTED/UPDATED so REVERSED/draft tickets don't leak into
        -- the live leg (Hard Rule #1). Confirmed live bug: TicketNumber
        -- 5194, branch 888, REVERSED, was inflating this branch's figures.
        SELECT
             td.BranchCode
            ,td.AccountCode
            ,SUM(ISNULL(td.Debit,0)) - SUM(ISNULL(td.Credit,0)) AS LiveDelta
        FROM TicketDetails td
        INNER JOIN BranchCutoff bc ON bc.BranchCode = td.BranchCode
        INNER JOIN TicketMaster tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE @IncludeLiveActivity = 1
          AND tm.Status IN ('POSTED', 'UPDATED')
          AND td.TicketDate >= DATEADD(day, 1, ISNULL(bc.Cutoff, '19000101'))
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
    -- CHANGE: drive FROM ChartOfAccounts (LEFT JOIN #LatestPosting,
    -- ISNULL to 0) instead of FROM #LatestPosting (INNER JOIN COA), so
    -- every detail BS account can be represented -- gated by
    -- @IncludeZeroActivity instead of unconditional, since this report
    -- exposes a checkbox rather than always showing zero accounts.
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

    -- ── SET 2: Section subtotals + balance check (unchanged -- summing in
    --    zero-balance accounts doesn't change any section's total) ───────
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
    -- FIX (sp-reviewer): a scope with zero BS activity in every section
    -- (e.g. a dormant/new branch) used to make SectionTotals -- and
    -- therefore the whole SET 2 output -- return ZERO rows entirely,
    -- since GROUP BY over an empty Combined has nothing to group. Drive
    -- from a fixed 5-section list instead so SET 2 always has one row per
    -- canonical section, with SectionTotal=0 where nothing exists.
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
        -- The 5 canonical sections, always present (zero-filled if empty).
        SELECT s.BSSection, CAST(ISNULL(SUM(c.Amount),0) AS DECIMAL(19,2)) AS SectionTotal
        FROM AllSections s
        LEFT JOIN Combined c ON c.BSSection = s.BSSection
        GROUP BY s.BSSection

        UNION ALL

        -- Anything outside the 5 canonical sections (e.g. a genuine
        -- '9-Other' account) still shows, but only when it actually has
        -- data -- unlike the canonical 5, it's not force-zero-filled.
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
   2. sp_rpt_IncomeStatementLiveWithDate
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
    ;WITH BranchScope AS
    (
        SELECT DISTINCT BranchCode FROM (
            SELECT BranchCode FROM Branches
            UNION
            SELECT BranchCode FROM GLSummary
            UNION
            SELECT BranchCode FROM TicketDetails
        ) allBranches
        WHERE (@BranchCode IS NULL OR BranchCode = @BranchCode)
    ),
    GLMaxDate AS
    (
        SELECT BranchCode, MAX(PostingDate) AS MaxPostingDate
        FROM GLSummary
        GROUP BY BranchCode
    ),
    BranchCutoff AS
    (
        SELECT
             bs.BranchCode
            ,COALESCE(pdc.LatestPostingDate, gmd.MaxPostingDate) AS Cutoff
        FROM BranchScope bs
        LEFT JOIN PostingDateControl pdc ON pdc.BranchCode = bs.BranchCode
        LEFT JOIN GLMaxDate          gmd ON gmd.BranchCode = bs.BranchCode
    ),
    PostedActivity AS
    (
        SELECT
             gs.AccountCode
            ,SUM(gs.Debits)       AS PeriodDebits
            ,SUM(ABS(gs.Credits)) AS PeriodCredits
        FROM GLSummary gs
        WHERE (@BranchCode IS NULL OR gs.BranchCode = @BranchCode)
          -- FIX (db-report-engineer): Hard Rule #4 -- never BETWEEN on a
          -- datetime column. Was `PostingDate BETWEEN @DateFrom AND
          -- @DateTo`; harmless today only because every GLSummary row in
          -- this DB posts at midnight, but fragile. House convention:
          AND gs.PostingDate >= @DateFrom
          AND gs.PostingDate <  DATEADD(DAY, 1, @DateTo)
        GROUP BY gs.AccountCode
    ),
    LiveActivity AS
    (
        -- Live window per branch starts the later of (that branch's
        -- cutoff+1 day) and @DateFrom -- GREATEST is safe at this DB's
        -- compat level 120 (confirmed in the T-SQL authoring skill).
        -- FIX (db-report-engineer): TicketDetails carries no Status of its
        -- own. Join TicketMaster on its natural key (TicketDate +
        -- SupplementaryNumber + BranchCode + TicketNumber, same pattern as
        -- Position/Movement in sql/01-exec-overview-data-layer.sql) and
        -- require POSTED/UPDATED so REVERSED/draft tickets don't leak into
        -- the live leg (Hard Rule #1).
        SELECT
             td.AccountCode
            ,SUM(ISNULL(td.Debit,0))  AS PeriodDebits
            ,SUM(ISNULL(td.Credit,0)) AS PeriodCredits
        FROM TicketDetails td
        INNER JOIN BranchCutoff bc ON bc.BranchCode = td.BranchCode
        INNER JOIN TicketMaster tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE @IncludeLiveActivity = 1
          AND tm.Status IN ('POSTED', 'UPDATED')
          AND td.TicketDate >= GREATEST(DATEADD(day, 1, ISNULL(bc.Cutoff, '19000101')), @DateFrom)
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
    -- CHANGE: drive FROM ChartOfAccounts (LEFT JOIN #CombinedActivity)
    -- instead of FROM #CombinedActivity (INNER JOIN ChartOfAccounts), so
    -- every detail IS account can be represented -- gated by
    -- @IncludeZeroActivity.
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

    -- ── SET 2: P&L Summary (unchanged math -- zero accounts contribute 0,
    --    consolidation is the same per-account SUM fed multi-branch data) ──
    -- FIX (sp-reviewer): every SUM() wrapped in ISNULL(...,0) -- a scope
    -- with zero matching IS accounts (a dormant/new branch, or a narrow
    -- date range) used to return one row of all-NULL totals instead of a
    -- proper all-zero row. Demonstrated live on branch 012.
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
   SMOKE TEST / VERIFICATION
   (all confirmed by hand on CORECSERP_002_DEV before this file was closed
    out -- see the engineer's report for the actual before/after numbers)
============================================================================ */
/*
-- 1. REVERSED ticket 5194 (branch 888, 2026-09-10) must no longer move the
--    live BS figures for an @AsOfDate on/after that date.
EXEC dbo.sp_rpt_BalanceSheetLiveWithDate
     @BranchCode = '888', @AsOfDate = '2026-09-12',
     @IncludeLiveActivity = 1, @IncludeZeroActivity = 1;

-- 2. Tie-out mode (skips the live leg entirely) must be byte-for-byte
--    identical to the posted-only procs, before and after this fix.
EXEC dbo.sp_rpt_BalanceSheetLiveWithDate
     @BranchCode = '888', @AsOfDate = '2026-07-24', @IncludeLiveActivity = 0;
EXEC dbo.sp_rpt_BalanceSheetWithDate
     @BranchCode = '888', @AsOfDate = '2026-07-24';

EXEC dbo.sp_rpt_IncomeStatementLiveWithDate
     @BranchCode = '888', @DateFrom = '2026-07-01', @DateTo = '2026-07-24',
     @IncludeLiveActivity = 0;
EXEC dbo.sp_rpt_IncomeStatementWithDate
     @BranchCode = '888', @DateFrom = '2026-07-01', @DateTo = '2026-07-24';

-- 3. NULL-branch "all branches" sentinel must still return real,
--    non-empty consolidated data.
EXEC dbo.sp_rpt_BalanceSheetLiveWithDate
     @BranchCode = NULL, @AsOfDate = '2026-09-12', @IncludeLiveActivity = 1;
EXEC dbo.sp_rpt_IncomeStatementLiveWithDate
     @BranchCode = NULL, @DateFrom = '2026-09-01', @DateTo = '2026-09-12',
     @IncludeLiveActivity = 1;

-- 4. A genuinely POSTED/UPDATED ticket dated after the cutoff must still
--    flow through @IncludeLiveActivity = 1 (proves the Status filter did
--    not over-filter legitimate current activity).
*/
