/* ============================================================================
   CORE REPORTING PORTAL — AR/AP GL MIGRATION-BLIND-SPOT FIX
   Target:     CORECSERP_002_DEV

   PROBLEM (confirmed live before writing anything below)
   ----------------------------------------------------------------------------
   dbo.sp_rpt_Exec_Summary (@ARTrade/@APTrade -> ReceivablesTrade/
   PayablesTrade) and dbo.sp_rpt_DataHealthCheck (checks #12/#13, the AR/AP
   subledger-vs-GL tie-out) both compute the AR/AP GL balance purely from
   TicketDetails/TicketMaster. Neither proc knows about dbo.GLSummary, which
   carries the old-system balance-forward posted during this ERP's migration.
   Both procs therefore understate the true GL balance for these control
   accounts by the entire pre-migration opening balance.

   SCHEMA CONFIRMED LIVE (INFORMATION_SCHEMA.COLUMNS, CORECSERP_002_DEV)
   ----------------------------------------------------------------------------
     GLSummary   BranchCode varchar(5) NOT NULL, PostingDate datetime NOT NULL,
                 SupplementaryNumber tinyint, AccountCode varchar(20) NOT NULL,
                 BeginningBalance money, Debits money, Credits money,
                 EndingBalance money NOT NULL.
     PostingDateControl (pre-existing base table, already used by
                 dbo.sp_rpt_BalanceSheetLiveWithDate / sp_rpt_
                 IncomeStatementLiveWithDate, sql/11-fix-live-proc-posted-
                 status-filter.sql): BranchCode varchar(50), LatestPostingDate
                 datetime NULL. Confirmed 0 rows in DEV today — every branch's
                 cutover therefore falls back generically to
                 MAX(GLSummary.PostingDate) for that branch, per the existing
                 proven pattern, not a hardcoded date.

   DATA FACTS VERIFIED LIVE (not assumed — this is a migration mid-flight,
   AP was explicitly unverified going in)
   ----------------------------------------------------------------------------
   - GLSummary carries a full balance-forward for EVERY branch (001-013, 888),
     same window: PostingDate 2026-07-01 through 2026-07-31, MAX = 2026-07-31
     for all 14 branches alike (generic, confirmed by GROUP BY BranchCode —
     not hardcoded to branch 888 or to this specific date).
   - For the AR control account (101030101) and all three AP control accounts
     (20101 AP-Trade, 20102 AP-Others, 20103 Accrued Expenses Payable),
     GLSummary rows exist for BranchCode = '888' ONLY (confirmed by GROUP BY
     BranchCode — AR/AP subledgers were consolidated at Head Office in the
     old system; other branches simply never had a GLSummary row for these
     four accounts, so their hybrid balance below is 100% live ticket
     movement, unaffected by this fix). Do NOT assume this stays true forever
     — the query below is branch-generic, not filtered to '888'.
   - TicketDetails activity for these four accounts starts strictly AFTER the
     GLSummary window (AR: 2026-08-01; AP 20103: 2026-08-03; AP 20101:
     2026-09-14; AP 20102: none at all yet) — zero overlap with the frozen
     GLSummary window, confirmed by MIN(TicketDate) per account.
   - AP migration IS present in GLSummary — the task brief's assumption that
     it might not be turned out to be checkable and true: all three AP
     control accounts have the same balance-forward pattern as AR.

   SIGN CONVENTION DISCOVERED (verified by cross-checking Nature against
   EndingBalance sign, both for the D-nature AR account and the C-nature AP
   accounts — not guessed)
   ----------------------------------------------------------------------------
   GLSummary.EndingBalance is stored in raw Debit-minus-Credit terms
   (positive = net debit), exactly like td.Debit - td.Credit:
     - 101030101 (Nature 'D'): EndingBalance = +165,433,465.56 (positive,
       matches an AR debit balance directly).
     - 20101/20102/20103 (Nature 'C'): EndingBalance = -676,102,564.22 /
       -34,918.28 / -72,188,691.03 (NEGATIVE — a credit-normal liability
       balance stored as a negative "debit-minus-credit" figure).
   So converting GLSummary.EndingBalance into the Hard-Rule-#5 Signed
   convention uses the exact same CASE already used everywhere else in this
   codebase: Nature 'D' -> EndingBalance as-is; Nature 'C' -> -EndingBalance.

   METHOD (mirrors the ALREADY-REVIEWED hybrid pattern in
   dbo.sp_rpt_BalanceSheetLiveWithDate / sp_rpt_IncomeStatementLiveWithDate,
   sql/11-fix-live-proc-posted-status-filter.sql, rather than inventing a new
   one) — for each branch:
     Cutover = COALESCE(PostingDateControl.LatestPostingDate,
                         MAX(GLSummary.PostingDate) for that branch)
     Hybrid balance (per AR/AP control account, per branch)
       = GLSummary.EndingBalance of the latest PostingDate <= Cutover
         (Signed per Nature, as above)
       + ticket movement (TicketDetails/TicketMaster, posted rows only,
         Hard Rule #1) STRICTLY AFTER Cutover, through the proc's own as-of
         boundary (Hard Rule #4: >= / < DATEADD(DAY,1,@AsOf))
   Branches with no GLSummary row for these four accounts simply get
   Cutover applied with a zero opening balance — full ticket history counts,
   unchanged from before this fix.

   OBJECTS TOUCHED
   ----------------------------------------------------------------------------
   dbo.sp_rpt_Exec_Summary        — @ARTrade/@APTrade (ReceivablesTrade/
                                     PayablesTrade). Same parameters, same
                                     result-set shape/column names. Only the
                                     AR/AP computation changes; Cash/
                                     InventoryOnHand/InventoryInTransit and
                                     every income-statement metric are
                                     untouched.
   dbo.sp_rpt_DataHealthCheck     — checks #12 (AR tie-out) and #13 (AP
                                     tie-out) @ARGL/@APGL computation only.
                                     Rewritten from the LIVE definition
                                     (confirmed via OBJECT_DEFINITION before
                                     editing — it had already diverged from
                                     sql/05-accounting-aging.sql: checks 1-11,
                                     14-18 unchanged verbatim, including the
                                     AP-EXP checks added in
                                     sql/09-apexp-aging.sql and check #13's
                                     2026-09-12 Trade+Expense subledger
                                     redefinition, both preserved as-is).

   Per this agent's DDL convention, the previous versions of both altered
   procedures are renamed with an _OLD_<timestamp> suffix before the new
   versions are created under the original names.
============================================================================ */


/* ============================================================================
   0. ARCHIVE THE CURRENT (PRE-FIX) PROCEDURES
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_Exec_Summary', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_Exec_Summary', 'sp_rpt_Exec_Summary_OLD_20260915';
GO

IF OBJECT_ID('dbo.sp_rpt_DataHealthCheck', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_DataHealthCheck', 'sp_rpt_DataHealthCheck_OLD_20260915';
GO


/* ============================================================================
   1. sp_rpt_Exec_Summary — AR/AP hybrid fix
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
       movement after each branch's cutover. See header note for the full
       investigation; this reuses the same hybrid cutover pattern already
       proven in dbo.sp_rpt_BalanceSheetLiveWithDate. ----------------------- */
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
        @ARLive = SUM(CASE WHEN t.AncestorCode = '101030101' THEN l.Signed END),
        @APLive = SUM(CASE WHEN t.AncestorCode IN ('20101', '20102', '20103') THEN l.Signed END)
    FROM #Line AS l
    INNER JOIN dbo.vw_AccountTree AS t ON t.AccountCode = l.AccountCode
    INNER JOIN #GLCutoff AS gc ON gc.BranchCode = l.BranchCode
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
   2. sp_rpt_DataHealthCheck — checks #12/#13 GL-side hybrid fix
   Rebuilt from the LIVE 18-check definition (confirmed via OBJECT_DEFINITION
   before editing). Checks 1-11 and 14-18 are copied verbatim, byte-for-byte
   unchanged. Only the @ARGL / @APGL computation inside checks #12/#13
   changes; check #13's @APSubledger (APAccounts + ExpenseSummary, redefined
   2026-09-12 per sql/09-apexp-aging.sql) is untouched.
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
       FIX 2026-09-15 (db-report-engineer): @ARGL/@APGL previously summed
       ONLY TicketDetails/TicketMaster, blind to dbo.GLSummary's migration
       balance-forward. Same hybrid cutover pattern as
       dbo.sp_rpt_BalanceSheetLiveWithDate (sql/11) and as
       dbo.sp_rpt_Exec_Summary (sql/12) — see that file's header for the full
       investigation (sign convention, cutover discovery, branch scope, all
       verified live, not assumed). Company-wide here (this proc has no
       @BranchCodes parameter), so no branch filter is applied to #GLCutoffHC. */
    CREATE TABLE #GLCutoffHC (BranchCode varchar(5) PRIMARY KEY, Cutoff datetime NULL);

    INSERT INTO #GLCutoffHC (BranchCode, Cutoff)
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
        ON gmd.BranchCode = bs.BranchCode;

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
        INNER JOIN #GLCutoffHC AS gc ON gc.BranchCode = td.BranchCode
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
        INNER JOIN #GLCutoffHC AS gc ON gc.BranchCode = td.BranchCode
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND coa.AccountType = 'D'
          AND td.TicketDate < @AsOfEnd
          AND (gc.Cutoff IS NULL OR td.TicketDate > gc.Cutoff)
          AND t.AncestorCode IN ('20101', '20102', '20103')
    );

    /* ---- 12. AR subledger total vs GL control account 101030101 --------
       @ARGL now = GLSummary migration opening (branch-hybrid) + live ticket
       movement after each branch's cutover, instead of ticket-only.
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
       sql/09-apexp-aging.sql for that investigation). @APGL now = GLSummary
       migration opening (branch-hybrid) + live ticket movement after each
       branch's cutover, instead of ticket-only — this was the actual gap
       this agent was asked to close; the Trade+Expense subledger
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
   SMOKE TEST
============================================================================ */
/*
-- Before/after comparison (run the _OLD_20260915 archived copies first if
-- you want a side-by-side, they are functionally identical to what was live
-- immediately before this script ran):
EXEC dbo.sp_rpt_Exec_Summary_OLD_20260915    @DateFrom = '2026-01-01', @DateTo = '2026-09-15';
EXEC dbo.sp_rpt_Exec_Summary                 @DateFrom = '2026-01-01', @DateTo = '2026-09-15';
EXEC dbo.sp_rpt_Exec_Summary                 @DateFrom = '2026-01-01', @DateTo = '2026-09-15', @BranchCodes = '888';
EXEC dbo.sp_rpt_Exec_Summary                 @DateFrom = '2026-01-01', @DateTo = '2026-09-15', @BranchCodes = '001';

EXEC dbo.sp_rpt_DataHealthCheck_OLD_20260915 @DateFrom = '2026-01-01', @DateTo = '2026-09-15';
EXEC dbo.sp_rpt_DataHealthCheck              @DateFrom = '2026-01-01', @DateTo = '2026-09-15';

-- Regression: branch 001 has no GLSummary row for 101030101/20101/20102/20103,
-- so its ReceivablesTrade/PayablesTrade must be UNCHANGED before/after this
-- fix (100% live ticket movement, no opening balance to add).
*/
