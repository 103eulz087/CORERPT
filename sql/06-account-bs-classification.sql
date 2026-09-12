/* ============================================================================
   CORE REPORTING PORTAL — ACCOUNTING MODULE: BALANCE SHEET CLASSIFICATION HELPER
   Target:     CORECSERP_002_DEV

   PROBLEM
   ----------------------------------------------------------------------------
   dbo.sp_rpt_BalanceSheetWithDate(@BranchCode, @AsOfDate) is developer-owned
   and NOT to be modified (other consumers may depend on its exact shape). It
   returns two result sets with no shared key between them:
     Set 1: AccountCode, AccountDescription, Amount, RawEndingBalance
            (one row per detail account, flat, no section/level info)
     Set 2: BSSection, SectionTotal, TotalAssets, TotalLiabilities, TotalEquity,
            AsOfDate, BranchCode
            (one row per section, grand totals denormalized onto every row)
   The Report Center needs to render an indented statement (Assets ->
   Current Assets -> Cash on Hand, etc.), which requires knowing each
   AccountCode's section and hierarchy depth — exactly what is missing.

   This script adds ONE new, additive, read-only view that the app queries
   alongside the existing proc and joins to Set 1 by AccountCode in the C#
   layer. It does not touch sp_rpt_BalanceSheetWithDate or
   sp_rpt_TrialBalanceWithDate in any way.

   SCHEMA CONFIRMED ON CORECSERP_002_DEV BEFORE WRITING ANYTHING BELOW
   ----------------------------------------------------------------------------
     ChartOfAccounts   AccountCode varchar(50) PK, Description varchar(256),
                       AccountType varchar(1)   ('D' = postable detail,
                                                  'S' = summary/non-postable —
                                                  Postability is AccountType,
                                                  NEVER LevelNumber, per Hard
                                                  Rule #3: detail accounts
                                                  exist at multiple levels),
                       LevelNumber smallint      (0 = root of a top-level
                                                  branch e.g. '1' ASSETS,
                                                  '2' LIABILITIES, '3' EQUITY,
                                                  '4' REVENUE, '5' COGS/EXPENSE;
                                                  increments walking down the
                                                  SummaryAccount chain — this
                                                  IS the account's true
                                                  hierarchy depth, confirmed
                                                  identical to
                                                  MAX(vw_AccountTree.Depth)
                                                  for every sample checked),
                       SummaryAccount varchar(20) (direct parent AccountCode;
                                                  a genuine SQL NULL for the
                                                  six top-level roots
                                                  (AccountCode '1'-'6',
                                                  AccountType='S') — confirmed
                                                  live (6 rows IS NULL, 0 rows
                                                  equal to the literal string
                                                  'NULL'). The NULLIF(...,'NULL')
                                                  below is defensive/inert
                                                  against today's data, kept
                                                  in case a future load ever
                                                  stores the literal string),
                       Nature char(1) ('D'/'C'), YearEndIndicator char(2)
                                                  ('BS' or 'IS' — confirmed the
                                                  authoritative statement-type
                                                  flag; sp_rpt_BalanceSheetWithDate
                                                  filters Set 1 on this).

     vw_AccountTree     Recursive view over ChartOfAccounts: one row per
                        (AccountCode, ancestor) pair, walking up the
                        SummaryAccount chain. AccountCode, Description,
                        AccountType, LevelNumber, YearEndIndicator, Nature,
                        DueToFromIndicator, AncestorCode, Depth (0 = self,
                        incrementing per level walked up). This is the ONLY
                        sanctioned way to test "is AccountCode a descendant of
                        root code X" (Hard Rule #3) — used below instead of
                        LIKE '101%' string matching.

     RptMnemonicMap     Mnemonic, Family, Description, IsInternal,
                        IsCrossBranch. Not used here — this view classifies
                        accounts, not journal mnemonics; nothing in
                        sp_rpt_BalanceSheetWithDate's BSSection derivation
                        touches mnemonics.

   HOW sp_rpt_BalanceSheetWithDate ACTUALLY DERIVES BSSection (read from
   sys.sql_modules — this is the ground truth this view must agree with)
   ----------------------------------------------------------------------------
   The proc's Set 2 CASE, verbatim account-code-prefix logic:
     AccountCode LIKE '101%'                    -> '1-Current Assets'
     AccountCode LIKE '102%'                    -> '2-Non-Current Assets'
     AccountCode LIKE '103%'                    -> '2-Non-Current Assets'
     AccountCode = '20202'  (checked BEFORE '202%') -> '3-Current Liabilities'
        -- proc's own comment: "Business-confirmed exception: ADVANCES FROM
        -- ACCOUNT MANAGERS is treated as a Current liability for this report
        -- despite rolling up under ChartOfAccounts SummaryAccount '202'
        -- (NON-CURRENT LIABILITIES)."
     AccountCode LIKE '201%'                    -> '3-Current Liabilities'
     AccountCode LIKE '202%'                    -> '4-Non-Current Liabilities'
     AccountCode LIKE '203%'                    -> '4-Non-Current Liabilities'
     AccountCode LIKE '3%'                      -> '5-Equity'
     ELSE                                       -> '9-Other'
   This IS a hardcoded account-code-range mapping inside the existing proc —
   a pre-existing violation of Hard Rule #3 in code we are told not to touch.
   Per the task brief's explicit instruction for this exact situation: mirror
   the proc's account-code-to-section RULE (same roots, same 20202 exception)
   but implement it through vw_AccountTree ancestry instead of LIKE string
   matching, so this new view itself complies with Hard Rule #3 while still
   tying out to the existing proc's totals.

   VERIFIED EQUIVALENCE (ran live against CORECSERP_002_DEV before building):
   Compared, for all 95 ChartOfAccounts rows where AccountType='D' AND
   YearEndIndicator='BS', the proc's LIKE-prefix section vs. this view's
   vw_AccountTree-ancestor section (with the same single 20202 override):
   ZERO mismatches. Breakdown (identical both ways):
     1-Current Assets............52   2-Non-Current Assets.........18
     3-Current Liabilities.......15   4-Non-Current Liabilities.....6
     5-Equity......................4
   No account fell into '9-Other' in either method — every BS detail account
   resolves to one of the five sections, so this view never needs to emit
   '9-Other' against today's chart of accounts (kept as a defensive ELSE only).

   WHAT THIS VIEW DOES NOT COVER
   ----------------------------------------------------------------------------
   - The proc's Set 1 also emits a synthetic 'CURRENT_EARNINGS' pseudo-row
     (label 'Current Period Earnings', the net of all YearEndIndicator='IS'
     accounts) that has no ChartOfAccounts row and therefore cannot appear in
     this view. The C# join must special-case AccountCode = 'CURRENT_EARNINGS'
     as BSSection = '5-Equity', IndentLevel = 1 (peer of the other Equity
     detail lines), ParentAccountCode = '3' — this is not a bug, it mirrors
     exactly how the proc itself folds current-period net income into Equity.
   - Revenue/COGS/Expense accounts (YearEndIndicator = 'IS', roots '4' and
     '5') are included in this view (AccountType='D' is the only filter) but
     resolve to BSSection = NULL, since they have no balance-sheet section —
     this is correct, not a gap. It is what makes the view usable for Trial
     Balance too (see recommendation below): a TB renderer can LEFT JOIN this
     view and simply not show a section badge on revenue/expense rows.

   TRIAL BALANCE RECOMMENDATION (sp_rpt_TrialBalanceWithDate)
   ----------------------------------------------------------------------------
   Read that proc's source too (sys.sql_modules): Set 1 is already a flat,
   AccountCode-sorted list of EVERY AccountType='D' account (BS and IS both),
   with EndingBalance / [TB Debit] / [TB Credit] / [Is Abnormal Balance], and
   Set 2 is a single Total Debit / Total Credit / Difference row — there is no
   section grouping or subtotal to tie out to in the first place (unlike the
   Balance Sheet proc's Set 2). Recommendation: render Trial Balance FLAT,
   sorted by AccountCode exactly as the proc returns it, and use
   [Is Abnormal Balance] as the oxblood/highlight signal per the design
   system's "money at risk" rationing rule — do NOT force TB into BS-style
   indentation. This view MAY optionally be LEFT JOINed in for a lightweight
   "Assets / Liabilities / Equity / (blank for Revenue+Expense)" group column
   if a future TB view groups by statement section, but that is not needed to
   ship a correct Trial Balance today, so it is not being built speculatively.
============================================================================ */

IF OBJECT_ID('dbo.vw_rpt_AccountBSClassification', 'V') IS NOT NULL
    DROP VIEW dbo.vw_rpt_AccountBSClassification;
GO

CREATE VIEW dbo.vw_rpt_AccountBSClassification
AS
SELECT
    coa.AccountCode,
    coa.Description                                    AS AccountDescription,
    coa.AccountType,
    coa.Nature,
    coa.YearEndIndicator,
    coa.LevelNumber                                    AS IndentLevel,
    NULLIF(coa.SummaryAccount, 'NULL')                 AS ParentAccountCode,
    CASE
        -- Business-confirmed exception, mirrored verbatim from
        -- sp_rpt_BalanceSheetWithDate: ADVANCES FROM ACCOUNT MANAGERS is a
        -- Current Liability for statement purposes despite structurally
        -- rolling up under SummaryAccount '202' (Non-Current Liabilities).
        -- MUST be evaluated before the general '202' ancestor check below.
        WHEN coa.AccountCode = '20202' THEN '3-Current Liabilities'

        WHEN EXISTS (SELECT 1 FROM dbo.vw_AccountTree t
                     WHERE t.AccountCode = coa.AccountCode AND t.AncestorCode = '101')
            THEN '1-Current Assets'

        WHEN EXISTS (SELECT 1 FROM dbo.vw_AccountTree t
                     WHERE t.AccountCode = coa.AccountCode AND t.AncestorCode = '102')
            THEN '2-Non-Current Assets'

        WHEN EXISTS (SELECT 1 FROM dbo.vw_AccountTree t
                     WHERE t.AccountCode = coa.AccountCode AND t.AncestorCode = '103')
            THEN '2-Non-Current Assets'

        WHEN EXISTS (SELECT 1 FROM dbo.vw_AccountTree t
                     WHERE t.AccountCode = coa.AccountCode AND t.AncestorCode = '201')
            THEN '3-Current Liabilities'

        WHEN EXISTS (SELECT 1 FROM dbo.vw_AccountTree t
                     WHERE t.AccountCode = coa.AccountCode AND t.AncestorCode = '202')
            THEN '4-Non-Current Liabilities'

        WHEN EXISTS (SELECT 1 FROM dbo.vw_AccountTree t
                     WHERE t.AccountCode = coa.AccountCode AND t.AncestorCode = '203')
            THEN '4-Non-Current Liabilities'

        WHEN EXISTS (SELECT 1 FROM dbo.vw_AccountTree t
                     WHERE t.AccountCode = coa.AccountCode AND t.AncestorCode = '3')
            THEN '5-Equity'

        -- YearEndIndicator = 'IS' accounts (Revenue root '4', COGS/Expense
        -- root '5') and anything else outside the six BS roots above:
        -- correctly NULL, not '9-Other' — see header note. Kept as a
        -- distinct branch (not folded into the same ELSE as a literal
        -- '9-Other' string) so a future genuinely-unclassified BS account
        -- is easy to tell apart from an ordinary IS account at a glance.
        WHEN coa.YearEndIndicator = 'BS' THEN '9-Other'
        ELSE NULL
    END AS BSSection
FROM dbo.ChartOfAccounts AS coa
WHERE coa.AccountType = 'D';   -- postable detail accounts only, per Hard Rule #3
GO


/* ============================================================================
   SMOKE TEST + TIE-OUT VERIFICATION

   Ties this view's per-account BSSection sums back to
   sp_rpt_BalanceSheetWithDate's own SectionTotal, joining only by
   AccountCode (Set 1 has no other key). Run for at least two
   @AsOfDate/@BranchCode combinations before trusting the join in the app.
============================================================================ */
/*
-- Basic shape check
SELECT TOP 20 * FROM dbo.vw_rpt_AccountBSClassification ORDER BY AccountCode;

-- No BS-type account should classify as '9-Other' or NULL today
SELECT * FROM dbo.vw_rpt_AccountBSClassification
WHERE YearEndIndicator = 'BS' AND (BSSection IS NULL OR BSSection = '9-Other');

-- ---- Tie-out #1: all branches, 2026-07-31 -----------------------------
IF OBJECT_ID('tempdb..#Set1') IS NOT NULL DROP TABLE #Set1;
CREATE TABLE #Set1 (AccountCode varchar(50), AccountDescription varchar(256), Amount decimal(19,2), RawEndingBalance decimal(19,2));
INSERT INTO #Set1 EXEC dbo.sp_rpt_BalanceSheetWithDate @BranchCode = NULL, @AsOfDate = '2026-07-31';

SELECT c.BSSection, SUM(s.Amount) AS MyViewSectionTotal
FROM #Set1 s
JOIN dbo.vw_rpt_AccountBSClassification c ON c.AccountCode = s.AccountCode
GROUP BY c.BSSection
ORDER BY c.BSSection;
-- Compare against: EXEC dbo.sp_rpt_BalanceSheetWithDate @BranchCode = NULL, @AsOfDate = '2026-07-31'; (2nd result set)
DROP TABLE #Set1;

-- ---- Tie-out #2: branch 888 (Head Office), 2026-07-31 ------------------
IF OBJECT_ID('tempdb..#Set1b') IS NOT NULL DROP TABLE #Set1b;
CREATE TABLE #Set1b (AccountCode varchar(50), AccountDescription varchar(256), Amount decimal(19,2), RawEndingBalance decimal(19,2));
INSERT INTO #Set1b EXEC dbo.sp_rpt_BalanceSheetWithDate @BranchCode = '888', @AsOfDate = '2026-07-31';

SELECT c.BSSection, SUM(s.Amount) AS MyViewSectionTotal
FROM #Set1b s
JOIN dbo.vw_rpt_AccountBSClassification c ON c.AccountCode = s.AccountCode
GROUP BY c.BSSection
ORDER BY c.BSSection;
-- Compare against: EXEC dbo.sp_rpt_BalanceSheetWithDate @BranchCode = '888', @AsOfDate = '2026-07-31'; (2nd result set)
DROP TABLE #Set1b;
*/
