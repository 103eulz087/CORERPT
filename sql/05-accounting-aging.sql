/* ============================================================================
   CORE REPORTING PORTAL — ACCOUNTING MODULE: AR / AP AGING
   Target:     CORECSERP_002_DEV (compat level 160, per 04-dev-compat-level-160.sql)

   Schema confirmed by reading INFORMATION_SCHEMA.COLUMNS on
   CORECSERP_002_DEV before writing anything below (no guessed column names):

     TransactionChargeSales  CustomerKey char(8)     NOT NULL
                              BranchCode  char(3)     NOT NULL  <- invoice's OWN
                                          branch. NEVER used for AR aging (per
                                          developer decision — see below).
                              TransactionDate date    NOT NULL  <- invoice date
                              ReferenceNo, InvoiceNo, TotalAmount,
                              Balance decimal         NOT NULL  <- open, already net
                              PayStatus, DueDate

     Customers                CustomerKey char(8)      PK
                               CustomerName varchar(150)         <- confirmed name col
                               CustomerCreditLimit money
                               Term float                        <- days
                               BranchCode varchar(100) NULLable  <- customer's HOME
                                          branch. THIS is what AR aging groups by.

     APAccounts                SupplierID varchar(30)  NOT NULL
                                InvoiceDate date        NOT NULL  <- real invoice date
                                InvoiceNo, Balance decimal NOT NULL, PayStatus, DueDate
                                No branch column anywhere on this table.

     Supplier                  SupplierKey char(6) PK, SupplierID varchar(250) NULLable
                                SupplierName varchar(250)          <- confirmed name col
                                Join key is SupplierID (matches APAccounts.SupplierID),
                                NOT SupplierKey.

   DATA-QUALITY FACTS VERIFIED DIRECTLY AGAINST DEV BEFORE CODING
   ----------------------------------------------------------------------------
   - AR: 0 of 9 currently-open TransactionChargeSales rows fail to match
     Customers.CustomerKey. 0 rows have Balance < 0. 0 rows have a NULL or
     future TransactionDate as of 2026-09-11.
   - AP: 316 of 640 currently-open APAccounts rows (SupplierID 000131/000132/
     000133) have no match in Supplier — ₱676,091,850.22 of ₱1,377,122,226.54
     open AP (49.1%). This is the exact fact called out in the task brief;
     surfaced below, never silently dropped via inner join.
   - GL tie-out (as of 2026-09-11, posted rows only):
       AR: subledger SUM(Balance) = 86,631.32   GL 101030101 = 86,631.32  -> ties exactly
       AP: subledger SUM(Balance) = 1,377,122,226.54   GL 20101/20102/20103 = 9,650.00
           -> a ~1.377-BILLION-PESO gap. This is a major, real finding — see the
           closing note at the bottom of this file. It is NOT something this
           script can fix; it is exactly what health check #12/#13 exists to
           surface every time this runs.

   CONVENTIONS (matched to 01-exec-overview-data-layer.sql)
   ----------------------------------------------------------------------------
   Date range      >= @Start AND < DATEADD(DAY,1,@AsOfDate)  (never BETWEEN)
   Branch codes    ALWAYS varchar, never converted to int
   Explicit CAST   on every result column (ADO.NET reader contract)
   Classification  vw_AccountTree + RptMnemonicMap for the DSO net-sales leg,
                   never a hardcoded account list beyond identifying the GL
                   control accounts (101030101 / 20101 / 20102 / 20103), which
                   is the one place Hard Rule #3 explicitly permits naming
                   codes — they ARE the target of the check, not a
                   classification shortcut.

   IMPORTANT SCOPE NOTE — subledger Balance has no history
   ----------------------------------------------------------------------------
   TransactionChargeSales.Balance and APAccounts.Balance are point-in-time
   CURRENT open balances; there is no snapshot table recording what the open
   balance was on an arbitrary past @AsOfDate. So @AsOfDate correctly ages the
   *invoice date* into buckets, but "open as of @AsOfDate" is only accurate
   when @AsOfDate is today (or the data hasn't moved since). Running this proc
   with a stale @AsOfDate against current data will silently misstate the
   Current bucket if invoices were paid down after that date. Flagging this as
   a data-quality/architecture risk, not fixing it here — a true point-in-time
   aging would need a subledger history/snapshot table that does not exist.
============================================================================ */


/* ============================================================================
   1. sp_rpt_AR_Aging

   Params:
     @AsOfDate     date              age everything relative to this date
     @BranchCodes  varchar(200)=NULL CSV of Customers.BranchCode values,
                                     NULL/empty = all branches (STRING_SPLIT)

   Branch = Customers.BranchCode (customer's HOME branch), never
   TransactionChargeSales.BranchCode (differs ~33% of the time per prior
   investigation — using it would silently misattribute AR to the wrong branch).

   Unknown-customer rows (CustomerKey with no Customers match) are LEFT
   JOINed, not dropped, and always pass the branch filter (their branch is
   unknowable, so filtering them out would be a second, quieter way of
   dropping them). Today's DEV data has zero such rows, but the risk class is
   the same as the AP unknown-supplier gap, so it is handled the same way.

   Result set 1: one row per customer, 5 buckets + totals + exposure.
   Result set 2: bucket rollup by branch + a grand-total row (for the chart).
   Result set 3: company-wide DSO (trailing 90 days, net-sales basis).
     DSO is deliberately NOT filtered by @BranchCodes and is NOT broken out
     per branch: AR aging here buckets by the customer's HOME branch, while
     the sales ledger's branch is the SELLING branch. Those are different
     axes — dividing a home-branch AR total by a selling-branch net-sales
     total would be an apples-to-oranges ratio. If a branch-level DSO is
     wanted later, decide which branch definition applies first.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_AR_Aging', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_AR_Aging;
GO

CREATE PROCEDURE dbo.sp_rpt_AR_Aging
    @AsOfDate    date,
    @BranchCodes varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /* ---- Branch filter, resolved once (empty table = no filter) --------- */
    CREATE TABLE #Branch (BranchCode varchar(100) PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(ISNULL(@BranchCodes, ''))), '') IS NOT NULL
        INSERT INTO #Branch (BranchCode)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@BranchCodes, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @FilterBranch bit = CASE WHEN EXISTS (SELECT 1 FROM #Branch) THEN 1 ELSE 0 END;

    /* ---- Open AR items, joined to the customer master once -------------- */
    CREATE TABLE #Open
    (
        CustomerKey  char(8)         NOT NULL,
        CustomerName varchar(200)    NOT NULL,
        BranchCode   varchar(100)    NULL,       -- NULL = customer master missing
        CreditLimit  money           NULL,
        Term         float           NULL,
        Balance      decimal(18,2)   NOT NULL,
        AgeDays      int             NOT NULL
    );

    INSERT INTO #Open (CustomerKey, CustomerName, BranchCode, CreditLimit, Term, Balance, AgeDays)
    SELECT
        t.CustomerKey,
        CustomerName = ISNULL(c.CustomerName, 'UNKNOWN CUSTOMER - ' + t.CustomerKey),
        c.BranchCode,
        c.CustomerCreditLimit,
        c.Term,
        t.Balance,
        AgeDays = DATEDIFF(DAY, t.TransactionDate, @AsOfDate)
    FROM dbo.TransactionChargeSales AS t
    LEFT JOIN dbo.Customers AS c
        ON c.CustomerKey = t.CustomerKey
    WHERE t.Balance > 0
      AND (@FilterBranch = 0
           OR c.BranchCode IN (SELECT BranchCode FROM #Branch)
           OR c.BranchCode IS NULL);   -- never silently drop unattributable rows

    /* ---- Result set 1: one row per customer ------------------------------ */
    SELECT
        CustomerKey       = CAST(CustomerKey AS char(8)),
        CustomerName      = CAST(CustomerName AS varchar(200)),
        BranchCode        = CAST(ISNULL(MAX(BranchCode), 'UNKNOWN') AS varchar(100)),
        CurrentAmount     = CAST(SUM(CASE WHEN AgeDays <= 0                THEN Balance ELSE 0 END) AS decimal(18,2)),
        PastDue1_30       = CAST(SUM(CASE WHEN AgeDays BETWEEN 1  AND 30   THEN Balance ELSE 0 END) AS decimal(18,2)),
        PastDue31_60      = CAST(SUM(CASE WHEN AgeDays BETWEEN 31 AND 60   THEN Balance ELSE 0 END) AS decimal(18,2)),
        PastDue61_90      = CAST(SUM(CASE WHEN AgeDays BETWEEN 61 AND 90   THEN Balance ELSE 0 END) AS decimal(18,2)),
        PastDue90Plus     = CAST(SUM(CASE WHEN AgeDays > 90                THEN Balance ELSE 0 END) AS decimal(18,2)),
        TotalOutstanding  = CAST(SUM(Balance) AS decimal(18,2)),
        CreditLimit       = CAST(MAX(CreditLimit) AS decimal(18,2)),
        Term              = CAST(MAX(Term) AS int),
        ExposurePct       = CAST(CASE WHEN MAX(CreditLimit) IS NULL OR MAX(CreditLimit) = 0 THEN NULL
                                       ELSE SUM(Balance) / NULLIF(MAX(CreditLimit), 0) * 100 END AS decimal(9,2)),
        OldestAgeDays     = CAST(MAX(AgeDays) AS int)
    FROM #Open
    GROUP BY CustomerKey, CustomerName
    ORDER BY TotalOutstanding DESC;

    /* ---- Result set 2: branch rollup + grand total -----------------------
       Every SUM wrapped in ISNULL(...,0) — a branch filter that matches zero
       customers (or an empty #Open) must not return NULL rollup columns to
       the ADO.NET reader (Bug 2 fix; matches the DSO section's existing
       ISNULL practice below). */
    SELECT
        BranchCode        = CAST(BranchCode AS varchar(100)),
        CurrentAmount     = CAST(ISNULL(SUM(CASE WHEN AgeDays <= 0                THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue1_30       = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 1  AND 30   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue31_60      = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 31 AND 60   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue61_90      = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 61 AND 90   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue90Plus     = CAST(ISNULL(SUM(CASE WHEN AgeDays > 90                THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        TotalOutstanding  = CAST(ISNULL(SUM(Balance), 0) AS decimal(18,2))
    FROM (SELECT ISNULL(BranchCode, 'UNKNOWN') AS BranchCode, Balance, AgeDays FROM #Open) AS x
    GROUP BY BranchCode

    UNION ALL

    SELECT
        BranchCode        = CAST('TOTAL' AS varchar(100)),
        CurrentAmount     = CAST(ISNULL(SUM(CASE WHEN AgeDays <= 0                THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue1_30       = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 1  AND 30   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue31_60      = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 31 AND 60   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue61_90      = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 61 AND 90   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue90Plus     = CAST(ISNULL(SUM(CASE WHEN AgeDays > 90                THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        TotalOutstanding  = CAST(ISNULL(SUM(Balance), 0) AS decimal(18,2))
    FROM #Open
    ORDER BY BranchCode;

    /* ---- Result set 3: company-wide DSO (trailing 90 days, net-sales basis)
       DSO = AR outstanding (all open items, as of @AsOfDate, unfiltered by
             @BranchCodes — see header note)
           / Net credit sales over the 90 calendar days ending @AsOfDate
             (posted rows only per Hard Rule #1; revenue accounts 401/402/
              40103, classified via vw_AccountTree per Hard Rule #3;
              IsInternal movements excluded per Hard Rule #7. This is
              computed independently here, NOT by calling or sharing code
              with sp_rpt_Exec_Summary's own @NetSales — that proc's
              @NetSales does not currently apply the IsInternal filter. The
              two happen to agree today only because no revenue mnemonic is
              flagged IsInternal=1 in RptMnemonicMap; if that changes, this
              calc and sp_rpt_Exec_Summary can diverge. See DDL review note,
              2026-09-12, for the decision to leave sp_rpt_Exec_Summary
              untouched in that pass.)
           * 90
       NULL when the trailing net-sales figure is <= 0 (divide-by-zero /
       meaningless ratio guard).

       AROutstanding for THIS ratio is deliberately re-queried from the base
       table (dbo.TransactionChargeSales), NOT read from #Open, because #Open
       already has @BranchCodes applied (Result Sets 1-2 need that). Reusing
       #Open here silently turned DSO into a branch-filtered-AR /
       company-wide-sales ratio whenever @BranchCodes was supplied — a
       ~4.8x distortion confirmed live (unfiltered DSO=89.0 vs
       @BranchCodes='888' DSO=18.4 against the same underlying data). Fixed
       2026-09-12; see header note above for why DSO must stay company-wide.
    ------------------------------------------------------------------------ */
    DECLARE @DsoWindowStart datetime = DATEADD(DAY, -89, CAST(@AsOfDate AS datetime));
    DECLARE @DsoWindowEnd   datetime = DATEADD(DAY,   1, CAST(@AsOfDate AS datetime));

    DECLARE @AROutstanding decimal(18,2) = (
        SELECT ISNULL(SUM(Balance), 0)
        FROM dbo.TransactionChargeSales
        WHERE Balance > 0);   -- unfiltered by @BranchCodes, on purpose (see above)
    DECLARE @NetSales90    decimal(18,2);

    SELECT @NetSales90 = ISNULL(SUM(CASE coa.Nature
                                         WHEN 'D' THEN td.Debit  - td.Credit
                                         ELSE          td.Credit - td.Debit
                                     END), 0)
    FROM dbo.TicketDetails AS td
    INNER JOIN dbo.TicketMaster AS tm
        ON  tm.TicketDate          = td.TicketDate
        AND tm.SupplementaryNumber = td.SupplementaryNumber
        AND tm.BranchCode          = td.BranchCode
        AND tm.TicketNumber        = td.TicketNumber
    LEFT JOIN dbo.RptMnemonicMap AS mm
        ON mm.Mnemonic = tm.Mnemonic
    INNER JOIN dbo.ChartOfAccounts AS coa
        ON coa.AccountCode = td.AccountCode
    INNER JOIN dbo.vw_AccountTree AS t
        ON t.AccountCode = td.AccountCode
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND coa.AccountType = 'D'
      AND td.TicketDate >= @DsoWindowStart
      AND td.TicketDate <  @DsoWindowEnd
      AND t.AncestorCode IN ('401', '402', '40103')
      AND ISNULL(mm.IsInternal, 0) = 0;

    SELECT
        AsOfDate         = CAST(@AsOfDate AS date),
        AROutstanding    = CAST(@AROutstanding AS decimal(18,2)),
        NetSales90Day    = CAST(@NetSales90 AS decimal(18,2)),
        TrailingDays     = CAST(90 AS int),
        DSO              = CAST(CASE WHEN ISNULL(@NetSales90, 0) <= 0 THEN NULL
                                      ELSE @AROutstanding / @NetSales90 * 90 END AS decimal(9,1));

    DROP TABLE #Open;
    DROP TABLE #Branch;
END
GO


/* ============================================================================
   2. sp_rpt_AP_Aging

   Params: @AsOfDate date ONLY. No branch parameter — per developer decision,
   AP aging is company-wide. APAccounts has no branch column, and the
   ShipmentNo -> ShipmentOrder join path is a dead end (ShipmentOrder is
   empty in DEV), so there is no reliable way to attribute AP to a branch.

   Unmatched-supplier rows (SupplierID with no Supplier match) are LEFT
   JOINed, not dropped — 316 of 640 open rows / ~49% of open AP dollar value
   in DEV today. They surface under 'UNKNOWN SUPPLIER - <code>'.

   Result set 1: one row per supplier, 5 buckets + totals.
   Result set 2: single company-wide rollup row.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_AP_Aging', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_AP_Aging;
GO

CREATE PROCEDURE dbo.sp_rpt_AP_Aging
    @AsOfDate date
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #Open
    (
        SupplierID   varchar(30)    NOT NULL,
        SupplierName varchar(300)   NOT NULL,
        Balance      decimal(18,2)  NOT NULL,
        AgeDays      int            NOT NULL
    );

    INSERT INTO #Open (SupplierID, SupplierName, Balance, AgeDays)
    SELECT
        a.SupplierID,
        SupplierName = ISNULL(s.SupplierName, 'UNKNOWN SUPPLIER - ' + a.SupplierID),
        a.Balance,
        AgeDays = DATEDIFF(DAY, a.InvoiceDate, @AsOfDate)
    FROM dbo.APAccounts AS a
    LEFT JOIN dbo.Supplier AS s
        ON s.SupplierID = a.SupplierID
    WHERE a.Balance > 0;

    /* ---- Result set 1: one row per supplier ------------------------------ */
    SELECT
        SupplierID        = CAST(SupplierID AS varchar(30)),
        SupplierName      = CAST(SupplierName AS varchar(300)),
        CurrentAmount     = CAST(SUM(CASE WHEN AgeDays <= 0                THEN Balance ELSE 0 END) AS decimal(18,2)),
        PastDue1_30       = CAST(SUM(CASE WHEN AgeDays BETWEEN 1  AND 30   THEN Balance ELSE 0 END) AS decimal(18,2)),
        PastDue31_60      = CAST(SUM(CASE WHEN AgeDays BETWEEN 31 AND 60   THEN Balance ELSE 0 END) AS decimal(18,2)),
        PastDue61_90      = CAST(SUM(CASE WHEN AgeDays BETWEEN 61 AND 90   THEN Balance ELSE 0 END) AS decimal(18,2)),
        PastDue90Plus     = CAST(SUM(CASE WHEN AgeDays > 90                THEN Balance ELSE 0 END) AS decimal(18,2)),
        TotalOutstanding  = CAST(SUM(Balance) AS decimal(18,2)),
        OldestAgeDays     = CAST(MAX(AgeDays) AS int)
    FROM #Open
    GROUP BY SupplierID, SupplierName
    ORDER BY TotalOutstanding DESC;

    /* ---- Result set 2: company-wide rollup, single row -------------------
       Every SUM wrapped in ISNULL(...,0) — this SELECT has no GROUP BY, so
       it always returns exactly one row even when #Open is empty; without
       ISNULL that row comes back all-NULL instead of all-0.00 (Bug 2 fix). */
    SELECT
        CurrentAmount     = CAST(ISNULL(SUM(CASE WHEN AgeDays <= 0                THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue1_30       = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 1  AND 30   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue31_60      = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 31 AND 60   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue61_90      = CAST(ISNULL(SUM(CASE WHEN AgeDays BETWEEN 61 AND 90   THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        PastDue90Plus     = CAST(ISNULL(SUM(CASE WHEN AgeDays > 90                THEN Balance ELSE 0 END), 0) AS decimal(18,2)),
        TotalOutstanding  = CAST(ISNULL(SUM(Balance), 0) AS decimal(18,2))
    FROM #Open;

    DROP TABLE #Open;
END
GO


/* ============================================================================
   3. HEALTH CHECK EXTENSION

   Extends dbo.sp_rpt_DataHealthCheck (v2, from 03-health-check-v2-and-
   findings.sql) rather than adding a separate proc, per the brief's
   preference for one health-check surface. Checks 1-7 are copied verbatim
   from v2 (SAME logic, unchanged). Checks 8-15 are new (AR/AP).

   New optional parameter @AsOfDate: the ledger checks (1-7) still key off
   @DateFrom/@DateTo exactly as before. The new AR/AP checks need a single
   as-of date instead of a range, so @AsOfDate defaults to @DateTo when not
   supplied — existing callers that only pass @DateFrom/@DateTo are
   unaffected and get AR/AP checked as of @DateTo.

   Output shape is UNCHANGED (CheckName, Severity, Findings, ValueAtRisk) —
   confirmed against Data/ReportRepository.cs, which reads these four columns
   by name via GetOrdinal, not by position or column count, so appending rows
   here is safe and does not break the existing Executive Overview reader.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_DataHealthCheck', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_DataHealthCheck;
GO

CREATE PROCEDURE dbo.sp_rpt_DataHealthCheck
    @DateFrom  date,
    @DateTo    date,
    @AsOfDate  date = NULL          -- AR/AP checks; defaults to @DateTo
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

    /* ---- 12. AR subledger total vs GL control account 101030101 --------
       Findings = 1 when the gap is nonzero (else 0). ValueAtRisk = the gap. */
    DECLARE @ARSubledger decimal(18,2) = (SELECT ISNULL(SUM(Balance), 0)
                                           FROM dbo.TransactionChargeSales WHERE Balance > 0);
    DECLARE @ARGL decimal(18,2) = (
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
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND coa.AccountType = 'D'
          AND td.TicketDate < @AsOfEnd
          AND t.AncestorCode = '101030101'
    );
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 12, 'AR subledger vs GL 101030101 tie-out gap', 'CRITICAL',
           CASE WHEN @ARSubledger <> @ARGL THEN 1 ELSE 0 END,
           ABS(@ARSubledger - @ARGL);

    /* ---- 13. AP subledger total vs GL control accounts 20101/20102/20103 */
    DECLARE @APSubledger decimal(18,2) = (SELECT ISNULL(SUM(Balance), 0)
                                           FROM dbo.APAccounts WHERE Balance > 0);
    DECLARE @APGL decimal(18,2) = (
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
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND coa.AccountType = 'D'
          AND td.TicketDate < @AsOfEnd
          AND t.AncestorCode IN ('20101','20102','20103')
    );
    INSERT INTO #Result (Seq, CheckName, Severity, Findings, ValueAtRisk)
    SELECT 13, 'AP subledger vs GL 20101/20102/20103 tie-out gap', 'CRITICAL',
           CASE WHEN @APSubledger <> @APGL THEN 1 ELSE 0 END,
           ABS(@APSubledger - @APGL);

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
EXEC dbo.sp_rpt_AR_Aging @AsOfDate = '2026-09-11';
EXEC dbo.sp_rpt_AR_Aging @AsOfDate = '2026-09-11', @BranchCodes = '888,001';

-- Bug 1 regression check: DSO (result set 3) must be IDENTICAL between these two,
-- since AROutstanding and NetSales90Day are both company-wide regardless of @BranchCodes.
EXEC dbo.sp_rpt_AR_Aging @AsOfDate = '2026-09-11', @BranchCodes = NULL;
EXEC dbo.sp_rpt_AR_Aging @AsOfDate = '2026-09-11', @BranchCodes = '888';

-- Bug 2 regression check: a branch filter matching zero customers must return a
-- TOTAL row of 0.00s (result set 2), never NULLs.
EXEC dbo.sp_rpt_AR_Aging @AsOfDate = '2026-09-11', @BranchCodes = 'ZZZ-NOMATCH';

EXEC dbo.sp_rpt_AP_Aging @AsOfDate = '2026-09-11';

EXEC dbo.sp_rpt_DataHealthCheck @DateFrom = '2026-07-01', @DateTo = '2026-09-11';
*/
