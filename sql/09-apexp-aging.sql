/* ============================================================================
   CORE REPORTING PORTAL — ACCOUNTING MODULE: AP-EXP (NON-TRADE PAYABLES) AGING
   Target:     CORECSERP_002_DEV (compat level 160, per 04-dev-compat-level-160.sql)

   Third aging report, alongside sp_rpt_AR_Aging / sp_rpt_AP_Aging
   (sql/05-accounting-aging.sql). Reference proc dbo.sp_Aging's 'AP-EXP'
   branch was read LIVE via OBJECT_DEFINITION(OBJECT_ID('dbo.sp_Aging')) on
   CORECSERP_002_DEV before writing anything below — it sources from
   dbo.ExpenseSummary (NOT APAccounts, which is trade AP, already covered by
   sp_rpt_AP_Aging), INNER JOINed to Supplier on SupplierID, ages off
   ExpenseDate against GETDATE(), and uses a 0-30/31-60/61-90/91-120/Over-120
   bucket scheme. This proc deliberately does NOT copy that bucket scheme —
   see below.

   SCHEMA CONFIRMED BY READING INFORMATION_SCHEMA.COLUMNS ON CORECSERP_002_DEV
   ----------------------------------------------------------------------------
     ExpenseSummary   ReferenceNumber varchar(10) NULL
                       InvoiceNo       varchar(150) NULL
                       SupplierID      char(6)      NULL   <- matches Supplier.SupplierID
                       Description     varchar(300) NULL
                       Status          varchar(50)  NULL   <- e.g. 'UNPAID', 'FULLYPAID'
                       Amount          money        NULL
                       ExpenseDate     date         NULL   <- aging date (no DueDate column
                                                               at all on this table, unlike
                                                               APAccounts)
                       Balance         decimal      NULL
                       AmountPaid, EWTAmount, DiscountAmount, OffsetAmount,
                       EWTWithheld, DiscountWithheld, OffsetWithheld  decimal NULL
                       ShipmentNo      varchar(10)  NULL
                       PostingMode     varchar(50)  NOT NULL   <- e.g. '', 'SINGLE'
                       PayableAccountCode varchar(20) NULL     <- see GL investigation below
                       No branch column anywhere on this table (same situation as
                       APAccounts — company-wide, no branch dimension).

     Supplier          SupplierKey char(6) PK, SupplierID varchar(250) NULLable
                       SupplierName varchar(250)
                       Join key is SupplierID (matches ExpenseSummary.SupplierID),
                       NOT SupplierKey — identical join convention to sp_rpt_AP_Aging.

   DATA-QUALITY FACTS VERIFIED DIRECTLY AGAINST DEV BEFORE CODING (as of 2026-09-12)
   ----------------------------------------------------------------------------
   - 479 open (Balance > 0) ExpenseSummary rows, 50 distinct SupplierID values,
     total open balance 91,988,914.51.
   - 0 rows with Balance < 0. 0 rows with NULL/future ExpenseDate. 0 rows with
     SupplierID having no match in Supplier. 0 rows with NULL SupplierID.
     Clean today — but the health checks below are added as STANDING
     assertions per house practice (05-accounting-aging.sql), not because
     today's data needs them; data can change.
   - PayableAccountCode on open rows splits 367 blank ('' / NULL, PostingMode
     blank, Status = 'UNPAID' — i.e. not yet posted to GL) / 112 = '20103'
     (PostingMode = 'SINGLE', Status = 'POSTED' — GL-posted rows).

   ----------------------------------------------------------------------------
   GL INVESTIGATION — DOES ExpenseSummary POST TO THE SAME 20101/20102/20103
   CONTROL-ACCOUNT FAMILY THAT HEALTH CHECK #13 (AP-TRADE TIE-OUT) MONITORS?
   ----------------------------------------------------------------------------
   YES — confirmed with an exact match, not a coincidence:

     The 112 open ExpenseSummary rows tagged PayableAccountCode = '20103'
     (PostingMode = 'SINGLE', Status = 'POSTED') sum to EXACTLY
     18,307,354.50. Querying dbo.TicketDetails/TicketMaster directly for
     AccountCode = '20103', Mnemonic = 'SINGLE', Status = 'POSTED' returns
     EXACTLY 112 rows summing to EXACTLY 18,307,354.50 (all Credit side,
     zero Debit). Same count, same amount, same posting-mode label —
     this is ExpenseSummary's own GL footprint.

   This means dbo.sp_rpt_DataHealthCheck check #13 ("AP subledger vs GL
   20101/20102/20103 tie-out gap") has an interpretation problem, not a
   computation bug: it correctly computes APAccounts.Balance vs the GL total
   under AncestorCode IN ('20101','20102','20103'), but that GL total is NOT
   pure APAccounts activity — it already includes whatever ExpenseSummary
   posts there. Live numbers as of 2026-09-12 make this stark:

       @APSubledger (APAccounts only)                    = 688,561,113.27
       @APGL (20101/20102/20103, posted+headered)        =  18,307,354.50
       Gap (check 13's current ValueAtRisk)               = 670,253,758.77

   ALL 18,307,354.50 of @APGL traces to ExpenseSummary's 112 SINGLE/POSTED
   rows — querying 20101 and 20102 alone (excluding 20103) for posted+
   headered activity returns ZERO rows. Every dollar of APAccounts' own
   real-world postings to 20101/20102 in this dataset sits in the ONE orphan
   (headerless) row per account already surfaced by check 13's own
   candidate-contributor branch in sp_rpt_DataHealthCheckDetail (Seq 13,
   result set 3) — none of it is currently POSTED+headered at all.

   Net effect: check 13's ValueAtRisk figure (670.25M) is arithmetically
   correct for what it is DEFINED to compute, but a reader who assumes
   "GLTotal here = AP-Trade GL activity only" would be wrong — right now
   100% of that GL total is actually ExpenseSummary's footprint, not
   APAccounts'. The check has NOT been "double counting" or overstating
   anything; if anything the current gap figure is arguably UNDERSTATED
   relative to what "APAccounts vs its true dedicated GL activity" would
   show, because the GL side is partly offset by a subledger (ExpenseSummary)
   that isn't APAccounts at all. Flagging this as a documented caveat on
   check 13, per the developer's request, rather than silently reinterpreting
   its number.

   The 367 blank-PayableAccountCode rows (Status = 'UNPAID', PostingMode
   blank, 73,681,560.01) show no evidence of having posted to GL yet — no
   corresponding TicketDetails/TicketMaster footprint was found for them;
   they read as pending/unposted expense accruals, not a different GL
   account family. This proc's aging figures still include them (they are
   real open subledger balances the business needs to see age), consistent
   with AR/AP aging showing subledger-open balances regardless of GL posting
   status — that has always been true of APAccounts/TransactionChargeSales
   too (see the point-in-time-balance caveat in 05-accounting-aging.sql).

   FOLLOW-UP DECIDED AND IMPLEMENTED (2026-09-12): the developer chose to
   REPLACE check 13's definition (same Seq number, not a new check 19) with
   the combined view: (APAccounts.Balance + ExpenseSummary.Balance) vs the
   SAME GL 20101/20102/20103 total, since both subledgers legitimately land
   in that control-account family. See the Seq 13 branches of
   dbo.sp_rpt_DataHealthCheck and dbo.sp_rpt_DataHealthCheckDetail below —
   CombinedSubledger = 688,561,113.27 + 91,988,914.51 = 780,550,027.78 vs
   GLTotal = 18,307,354.50 -> Gap = 762,242,673.28, confirmed live as of
   2026-09-12 (window 2026-07-01 to 2026-09-12). This is a larger, more
   honest gap than the prior APAccounts-only figure (670,253,758.77) — it
   stops crediting the GL side with dollars that belong to a subledger the
   check didn't add on the other side. CheckName updated to "AP
   (Trade+Expense) subledger vs GL 20101/20102/20103 tie-out gap" for
   clarity; flagged for accounting-reviewer since it redefines an
   already-displayed financial figure.

   ----------------------------------------------------------------------------
   BUCKET SCHEME — DELIBERATELY NOT THE REFERENCE PROC'S SCHEME
   ----------------------------------------------------------------------------
   dbo.sp_Aging's AP-EXP branch uses 0-30/31-60/61-90/91-120/Over-120 (and
   ages off GETDATE(), not a parameter). This proc uses the SAME 5-bucket
   scheme as sp_rpt_AR_Aging/sp_rpt_AP_Aging (Current/1-30/31-60/61-90/90+,
   aged via DATEDIFF(DAY, ExpenseDate, @AsOfDate)) so all three of this
   portal's aging reports read consistently against each other, per explicit
   developer instruction.

   CONVENTIONS (matched to 05-accounting-aging.sql)
   ----------------------------------------------------------------------------
   Explicit CAST      on every result column (ADO.NET reader contract, Hard Rule #8)
   Unmatched supplier  LEFT JOINed, never dropped, labeled 'UNKNOWN SUPPLIER - <id>'
   No branch parameter  ExpenseSummary has no branch column (same as APAccounts)
   ISNULL(...,0)       on every aggregate in the no-GROUP-BY rollup result set
============================================================================ */


/* ============================================================================
   1. sp_rpt_APEXP_Aging

   Params: @AsOfDate date ONLY. No branch parameter — ExpenseSummary has no
   branch column, matching the AP-Trade (sp_rpt_AP_Aging) design decision.

   Unmatched-supplier rows (SupplierID with no Supplier match) are LEFT
   JOINed, not dropped — same risk class as sp_rpt_AP_Aging's unknown-
   supplier handling, even though today's DEV data has zero such rows.

   Result set 1: one row per supplier, 5 buckets + totals + oldest age.
   Result set 2: single company-wide rollup row, ISNULL(...,0) wrapped.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_APEXP_Aging', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_APEXP_Aging;
GO

CREATE PROCEDURE dbo.sp_rpt_APEXP_Aging
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
        e.SupplierID,
        SupplierName = ISNULL(s.SupplierName, 'UNKNOWN SUPPLIER - ' + e.SupplierID),
        e.Balance,
        AgeDays = DATEDIFF(DAY, e.ExpenseDate, @AsOfDate)
    FROM dbo.ExpenseSummary AS e
    LEFT JOIN dbo.Supplier AS s
        ON s.SupplierID = e.SupplierID
    WHERE e.Balance > 0;

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
       ISNULL that row comes back all-NULL instead of all-0.00 (same lesson
       as the AR/AP DSO fix documented in 05-accounting-aging.sql). */
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
   2. HEALTH CHECK EXTENSION — Seq 16, 17, 18 (AP-EXP / ExpenseSummary)

   Extends dbo.sp_rpt_DataHealthCheck. Seq 1-15 are UNCHANGED (copied
   verbatim from sql/05-accounting-aging.sql, confirmed against the LIVE
   OBJECT_DEFINITION before this edit). New checks mirror the exact same
   three check types already applied to AR (8/10/14) and AP (9/11/15):
   unaged date, unknown supplier/customer, negative balance — now applied to
   ExpenseSummary. Deliberately NOT adding an AP-EXP-vs-GL tie-out check yet
   (that depends on the developer's decision on the proposal above).

   @AsOfDate already exists on this proc (defaults to @DateTo) — the new
   checks reuse it exactly like checks 8/9/10/11/14/15 do; no signature
   change needed.
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

    /* ---- 13. AP (Trade+Expense) subledger total vs GL control accounts
       20101/20102/20103
       REDEFINED 2026-09-12, per developer decision (same check/Seq number —
       the UI is built against Seq, not CheckName): the prior version of this
       check compared APAccounts (trade AP) ALONE against the GL total for
       20101/20102/20103. That GL total is also populated by ExpenseSummary
       (non-trade AP-Expense — see sp_rpt_APEXP_Aging in
       sql/09-apexp-aging.sql), CONFIRMED by exact match: ExpenseSummary's
       112 open rows tagged PayableAccountCode='20103' sum to EXACTLY
       18,307,354.50, matching live TicketDetails/TicketMaster postings at
       AccountCode='20103', Mnemonic='SINGLE', Status='POSTED' row-for-row.
       As of 2026-09-12, 100% of @APGL traced to ExpenseSummary and 0% to
       APAccounts' own posted+headered activity — i.e. the old check was
       crediting the GL side with a subledger it never added to the
       subledger side. @APSubledger now sums BOTH subledgers' open balances
       (APAccounts.Balance + ExpenseSummary.Balance); @APGL (the GL side) is
       UNCHANGED — it was already correct, the bug was only ever on the
       subledger side excluding ExpenseSummary. */
    DECLARE @APSubledger decimal(18,2) = (SELECT ISNULL(SUM(Balance), 0)
                                           FROM dbo.APAccounts WHERE Balance > 0)
                                        + (SELECT ISNULL(SUM(Balance), 0)
                                           FROM dbo.ExpenseSummary WHERE Balance > 0);
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
    SELECT 13, 'AP (Trade+Expense) subledger vs GL 20101/20102/20103 tie-out gap', 'CRITICAL',
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
   3. HEALTH CHECK DETAIL EXTENSION — Seq 16, 17, 18

   Extends dbo.sp_rpt_DataHealthCheckDetail (sql/08-health-check-detail.sql).
   Seq 1-15 branches are UNCHANGED (copied verbatim from the live proc
   definition, confirmed via OBJECT_DEFINITION before this edit). New
   branches 16/17/18 follow the exact same mechanical row-filter pattern as
   the equivalent AR (8/10/14) and AP (9/11/15) branches: same predicate as
   the aggregate check, SELECT the row instead of COUNT/SUM, TOP 500, most
   material first. No DueDate column exists on ExpenseSummary (confirmed via
   INFORMATION_SCHEMA), so these branches omit it — unlike the AP (9/11/15)
   branches, which do carry APAccounts.DueDate.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_DataHealthCheckDetail', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_DataHealthCheckDetail;
GO

CREATE PROCEDURE dbo.sp_rpt_DataHealthCheckDetail
    @Seq       int,
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

    /* ==== 1. Unbalanced tickets (standard) — line items per offending ticket ==== */
    IF @Seq = 1
    BEGIN
        ;WITH Offending AS
        (
            SELECT td.TicketDate, td.SupplementaryNumber, td.BranchCode, td.TicketNumber,
                   Variance = SUM(td.Debit) - SUM(td.Credit)
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
        ),
        TopTickets AS
        (
            SELECT TOP (200) * FROM Offending ORDER BY ABS(Variance) DESC
        )
        SELECT
            TicketDate          = CAST(o.TicketDate AS date),
            BranchCode          = CAST(o.BranchCode AS varchar(5)),
            BranchName          = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            TicketNumber        = CAST(o.TicketNumber AS varchar(50)),
            SupplementaryNumber = CAST(o.SupplementaryNumber AS tinyint),
            ReferenceNumber     = CAST(ISNULL(tm.ReferenceNumber, '') AS varchar(150)),
            Mnemonic            = CAST(ISNULL(tm.Mnemonic, '') AS varchar(50)),
            AccountCode         = CAST(td.AccountCode AS varchar(20)),
            AccountName         = CAST(ISNULL(coa.Description, '') AS varchar(256)),
            Debit               = CAST(td.Debit AS decimal(18,2)),
            Credit              = CAST(td.Credit AS decimal(18,2)),
            Particulars         = CAST(ISNULL(td.Particulars, '') AS varchar(400)),
            TicketVariance      = CAST(o.Variance AS decimal(18,2))
        FROM TopTickets AS o
        INNER JOIN dbo.TicketDetails AS td
            ON  td.TicketDate          = o.TicketDate
            AND td.SupplementaryNumber = o.SupplementaryNumber
            AND td.BranchCode          = o.BranchCode
            AND td.TicketNumber        = o.TicketNumber
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = o.TicketDate
            AND tm.SupplementaryNumber = o.SupplementaryNumber
            AND tm.BranchCode          = o.BranchCode
            AND tm.TicketNumber        = o.TicketNumber
        LEFT JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = o.BranchCode
        ORDER BY ABS(o.Variance) DESC, o.TicketNumber, td.AccountCode;
        RETURN;
    END

    /* ==== 2. Unbalanced cross-branch sets — one row per offending ReferenceNumber ==== */
    IF @Seq = 2
    BEGIN
        SELECT TOP (500)
            ReferenceNumber   = CAST(tm.ReferenceNumber AS varchar(150)),
            SampleMnemonic    = CAST(MIN(tm.Mnemonic) AS varchar(50)),
            TicketCount       = CAST(COUNT(DISTINCT CONCAT(tm.TicketDate, '|', tm.SupplementaryNumber, '|', tm.BranchCode, '|', tm.TicketNumber)) AS int),
            BranchesInvolved  = CAST(COUNT(DISTINCT tm.BranchCode) AS int),
            FirstTicketDate   = CAST(MIN(td.TicketDate) AS date),
            LastTicketDate    = CAST(MAX(td.TicketDate) AS date),
            TotalDebit        = CAST(SUM(td.Debit) AS decimal(18,2)),
            TotalCredit       = CAST(SUM(td.Credit) AS decimal(18,2)),
            Variance          = CAST(SUM(td.Debit) - SUM(td.Credit) AS decimal(18,2))
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
        ORDER BY ABS(SUM(td.Debit) - SUM(td.Credit)) DESC;
        RETURN;
    END

    /* ==== 3. Orphan detail rows — mechanical, no TicketMaster to join to ==== */
    IF @Seq = 3
    BEGIN
        SELECT TOP (500)
            TicketDate          = CAST(td.TicketDate AS date),
            BranchCode          = CAST(td.BranchCode AS varchar(5)),
            TicketNumber        = CAST(td.TicketNumber AS varchar(50)),
            SupplementaryNumber = CAST(td.SupplementaryNumber AS tinyint),
            ReferenceNumber     = CAST(ISNULL(td.ReferenceNumber, '') AS varchar(50)),
            ReferenceKey        = CAST(ISNULL(td.ReferenceKey, '') AS varchar(50)),
            AccountCode         = CAST(td.AccountCode AS varchar(20)),
            AccountName         = CAST(ISNULL(coa.Description, '') AS varchar(256)),
            Debit               = CAST(td.Debit AS decimal(18,2)),
            Credit              = CAST(td.Credit AS decimal(18,2)),
            Particulars         = CAST(ISNULL(td.Particulars, '') AS varchar(400))
        FROM dbo.TicketDetails AS td
        LEFT JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
        WHERE td.TicketDate >= @Start AND td.TicketDate < @End
          AND NOT EXISTS (
                SELECT 1 FROM dbo.TicketMaster AS tm
                WHERE tm.TicketDate          = td.TicketDate
                  AND tm.SupplementaryNumber = td.SupplementaryNumber
                  AND tm.BranchCode          = td.BranchCode
                  AND tm.TicketNumber        = td.TicketNumber)
        ORDER BY ABS(td.Debit + td.Credit) DESC;
        RETURN;
    END

    /* ==== 4. Postings to summary accounts — TicketMaster is display-only ==== */
    IF @Seq = 4
    BEGIN
        SELECT TOP (500)
            TicketDate      = CAST(td.TicketDate AS date),
            BranchCode      = CAST(td.BranchCode AS varchar(5)),
            BranchName      = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            TicketNumber    = CAST(td.TicketNumber AS varchar(50)),
            ReferenceNumber = CAST(ISNULL(tm.ReferenceNumber, td.ReferenceNumber) AS varchar(150)),
            Mnemonic        = CAST(ISNULL(tm.Mnemonic, '') AS varchar(50)),
            Status          = CAST(ISNULL(tm.Status, '') AS varchar(50)),
            AccountCode     = CAST(td.AccountCode AS varchar(20)),
            AccountName     = CAST(coa.Description AS varchar(256)),
            Debit           = CAST(td.Debit AS decimal(18,2)),
            Credit          = CAST(td.Credit AS decimal(18,2)),
            Particulars     = CAST(ISNULL(td.Particulars, '') AS varchar(400))
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
        LEFT JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = td.BranchCode
        WHERE td.TicketDate >= @Start AND td.TicketDate < @End
          AND coa.AccountType = 'S'
        ORDER BY (td.Debit + td.Credit) DESC;
        RETURN;
    END

    /* ==== 5. Unknown account codes — TicketMaster is display-only ==== */
    IF @Seq = 5
    BEGIN
        SELECT TOP (500)
            TicketDate      = CAST(td.TicketDate AS date),
            BranchCode      = CAST(td.BranchCode AS varchar(5)),
            TicketNumber    = CAST(td.TicketNumber AS varchar(50)),
            ReferenceNumber = CAST(ISNULL(tm.ReferenceNumber, td.ReferenceNumber) AS varchar(150)),
            Mnemonic        = CAST(ISNULL(tm.Mnemonic, '') AS varchar(50)),
            AccountCode     = CAST(td.AccountCode AS varchar(20)),
            Debit           = CAST(td.Debit AS decimal(18,2)),
            Credit          = CAST(td.Credit AS decimal(18,2)),
            Particulars     = CAST(ISNULL(td.Particulars, '') AS varchar(400))
        FROM dbo.TicketDetails AS td
        LEFT JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE td.TicketDate >= @Start AND td.TicketDate < @End
          AND NOT EXISTS (SELECT 1 FROM dbo.ChartOfAccounts AS coa
                          WHERE coa.AccountCode = td.AccountCode)
        ORDER BY (td.Debit + td.Credit) DESC;
        RETURN;
    END

    /* ==== 6. Unmapped mnemonics — grouped, with occurrence count + samples ==== */
    IF @Seq = 6
    BEGIN
        ;WITH Bad AS
        (
            SELECT
                tm.Mnemonic, tm.TicketNumber, tm.TicketDate,
                rn = ROW_NUMBER() OVER (PARTITION BY tm.Mnemonic ORDER BY tm.TicketDate DESC)
            FROM dbo.TicketMaster AS tm
            WHERE tm.TicketDate >= @Start AND tm.TicketDate < @End
              AND tm.Status IN ('POSTED','UPDATED')
              AND tm.Mnemonic IS NOT NULL
              AND NOT EXISTS (SELECT 1 FROM dbo.RptMnemonicMap AS mm
                              WHERE mm.Mnemonic = tm.Mnemonic)
        )
        SELECT TOP (500)
            Mnemonic            = CAST(Mnemonic AS varchar(50)),
            OccurrenceCount     = CAST(COUNT(*) AS int),
            FirstSeen           = CAST(MIN(TicketDate) AS date),
            LastSeen            = CAST(MAX(TicketDate) AS date),
            SampleTicketNumbers = CAST(
                STRING_AGG(CASE WHEN rn <= 2 THEN TicketNumber END, ', ')
                    WITHIN GROUP (ORDER BY rn) AS varchar(200))
        FROM Bad
        GROUP BY Mnemonic
        ORDER BY OccurrenceCount DESC;
        RETURN;
    END

    /* ==== 7. Unknown branch codes — mechanical row filter ==== */
    IF @Seq = 7
    BEGIN
        SELECT TOP (500)
            TicketDate      = CAST(td.TicketDate AS date),
            BranchCode      = CAST(td.BranchCode AS varchar(5)),
            TicketNumber    = CAST(td.TicketNumber AS varchar(50)),
            ReferenceNumber = CAST(ISNULL(tm.ReferenceNumber, td.ReferenceNumber) AS varchar(150)),
            Mnemonic        = CAST(ISNULL(tm.Mnemonic, '') AS varchar(50)),
            AccountCode     = CAST(td.AccountCode AS varchar(20)),
            Debit           = CAST(td.Debit AS decimal(18,2)),
            Credit          = CAST(td.Credit AS decimal(18,2))
        FROM dbo.TicketDetails AS td
        LEFT JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE td.TicketDate >= @Start AND td.TicketDate < @End
          AND NOT EXISTS (SELECT 1 FROM dbo.Branches AS b
                          WHERE b.BranchCode = td.BranchCode)
        ORDER BY (td.Debit + td.Credit) DESC;
        RETURN;
    END

    /* ==== 8. AR open items with unaged date ==== */
    IF @Seq = 8
    BEGIN
        SELECT TOP (500)
            CustomerKey     = CAST(t.CustomerKey AS char(8)),
            CustomerName    = CAST(ISNULL(c.CustomerName, 'UNKNOWN CUSTOMER - ' + t.CustomerKey) AS varchar(200)),
            BranchCode      = CAST(ISNULL(c.BranchCode, '') AS varchar(100)),
            InvoiceNo       = CAST(ISNULL(t.InvoiceNo, '') AS varchar(100)),
            ReferenceNo     = CAST(ISNULL(t.ReferenceNo, '') AS varchar(20)),
            TransactionDate = CAST(t.TransactionDate AS date),
            DueDate         = CAST(t.DueDate AS date),
            Balance         = CAST(t.Balance AS decimal(18,2)),
            PayStatus       = CAST(ISNULL(t.PayStatus, '') AS varchar(10))
        FROM dbo.TransactionChargeSales AS t
        LEFT JOIN dbo.Customers AS c ON c.CustomerKey = t.CustomerKey
        WHERE t.Balance > 0
          AND (t.TransactionDate IS NULL OR t.TransactionDate > @AsOfDate)
        ORDER BY t.Balance DESC;
        RETURN;
    END

    /* ==== 9. AP open items with unaged date ==== */
    IF @Seq = 9
    BEGIN
        SELECT TOP (500)
            SupplierID      = CAST(a.SupplierID AS varchar(30)),
            SupplierName    = CAST(ISNULL(s.SupplierName, 'UNKNOWN SUPPLIER - ' + a.SupplierID) AS varchar(300)),
            InvoiceNo       = CAST(ISNULL(a.InvoiceNo, '') AS varchar(80)),
            ReferenceNumber = CAST(ISNULL(a.ReferenceNumber, '') AS char(5)),
            InvoiceDate     = CAST(a.InvoiceDate AS date),
            DueDate         = CAST(a.DueDate AS date),
            Balance         = CAST(a.Balance AS decimal(18,2)),
            PayStatus       = CAST(ISNULL(a.PayStatus, '') AS varchar(20))
        FROM dbo.APAccounts AS a
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = a.SupplierID
        WHERE a.Balance > 0
          AND (a.InvoiceDate IS NULL OR a.InvoiceDate > @AsOfDate)
        ORDER BY a.Balance DESC;
        RETURN;
    END

    /* ==== 10. AR open items with unknown CustomerKey ====
       InvoiceBranchCode (not "BranchCode") deliberately — this is
       TransactionChargeSales.BranchCode, the invoice's OWN branch, NOT the
       customer's home branch (which is unknowable here since the customer
       master row doesn't exist). Naming it plainly avoids repeating the
       exact attribution bug documented in sql/05-accounting-aging.sql. */
    IF @Seq = 10
    BEGIN
        SELECT TOP (500)
            CustomerKey       = CAST(t.CustomerKey AS char(8)),
            InvoiceBranchCode = CAST(t.BranchCode AS varchar(5)),
            InvoiceNo         = CAST(ISNULL(t.InvoiceNo, '') AS varchar(100)),
            ReferenceNo       = CAST(ISNULL(t.ReferenceNo, '') AS varchar(20)),
            TransactionDate   = CAST(t.TransactionDate AS date),
            DueDate           = CAST(t.DueDate AS date),
            Balance           = CAST(t.Balance AS decimal(18,2)),
            PayStatus         = CAST(ISNULL(t.PayStatus, '') AS varchar(10))
        FROM dbo.TransactionChargeSales AS t
        WHERE t.Balance > 0
          AND NOT EXISTS (SELECT 1 FROM dbo.Customers AS c WHERE c.CustomerKey = t.CustomerKey)
        ORDER BY t.Balance DESC;
        RETURN;
    END

    /* ==== 11. AP open items with unknown SupplierID ==== */
    IF @Seq = 11
    BEGIN
        SELECT TOP (500)
            SupplierID      = CAST(a.SupplierID AS varchar(30)),
            InvoiceNo       = CAST(ISNULL(a.InvoiceNo, '') AS varchar(80)),
            ReferenceNumber = CAST(ISNULL(a.ReferenceNumber, '') AS char(5)),
            InvoiceDate     = CAST(a.InvoiceDate AS date),
            DueDate         = CAST(a.DueDate AS date),
            Balance         = CAST(a.Balance AS decimal(18,2)),
            PayStatus       = CAST(ISNULL(a.PayStatus, '') AS varchar(20))
        FROM dbo.APAccounts AS a
        WHERE a.Balance > 0
          AND NOT EXISTS (SELECT 1 FROM dbo.Supplier AS s WHERE s.SupplierID = a.SupplierID)
        ORDER BY a.Balance DESC;
        RETURN;
    END

    /* ==== 12/13. Tie-out gaps — unchanged from sql/08-health-check-detail.sql ==== */
    IF @Seq = 12
    BEGIN
        DECLARE @ARSubledger12 decimal(18,2) = (SELECT ISNULL(SUM(Balance), 0)
                                                 FROM dbo.TransactionChargeSales WHERE Balance > 0);
        DECLARE @ARGL12 decimal(18,2) = (
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
        DECLARE @ARGap12 decimal(18,2) = @ARSubledger12 - @ARGL12;   -- signed: + => subledger > GL

        SELECT
            Seq            = CAST(12 AS int),
            CheckName      = CAST('AR subledger vs GL 101030101 tie-out gap' AS varchar(80)),
            AsOfDate       = CAST(@AsOfDate AS date),
            SubledgerTotal = CAST(@ARSubledger12 AS decimal(18,2)),
            GLTotal        = CAST(@ARGL12 AS decimal(18,2)),
            Gap            = CAST(@ARGap12 AS decimal(18,2)),
            AbsGap         = CAST(ABS(@ARGap12) AS decimal(18,2)),
            GapDirection   = CAST(CASE WHEN @ARGap12 > 0 THEN 'SUBLEDGER EXCEEDS GL'
                                        WHEN @ARGap12 < 0 THEN 'GL EXCEEDS SUBLEDGER'
                                        ELSE 'TIED OUT' END AS varchar(30));

        SELECT BlindSpot = CAST(x.v AS varchar(400)) FROM (VALUES
            ('A posted/headered ticket booked to the WRONG account (miscoded to a different account, including a different control account) is invisible here: it has a TicketMaster row, so it nets straight into GLTotal above with no discrepancy flagged, and will never appear in the candidate list below.'),
            ('A Status value typo or unexpected value (anything not exactly POSTED or UPDATED) silently drops that ticket''s lines from GLTotal with no error. The ticket still has a TicketMaster row, so it is not an orphan and will not appear below.'),
            ('A subledger-side data error — a TransactionChargeSales row with no TicketDetails counterpart at all (e.g. a manual balance adjustment made directly on the subledger table) changes SubledgerTotal above with zero footprint in TicketDetails. There is no detail row to surface as a candidate.'),
            ('AsOfDate vs. live snapshot: TransactionChargeSales.Balance is a CURRENT point-in-time balance (no history table). SubledgerTotal above always reflects TODAY''s balance regardless of @AsOfDate, while GLTotal is correctly bounded by @AsOfDate. A stale @AsOfDate can produce or mask a gap unrelated to any row below.')
        ) AS x(v);

        SELECT TOP (500)
            TicketDate             = CAST(td.TicketDate AS date),
            BranchCode              = CAST(td.BranchCode AS varchar(5)),
            TicketNumber            = CAST(td.TicketNumber AS varchar(50)),
            SupplementaryNumber     = CAST(td.SupplementaryNumber AS tinyint),
            ReferenceNumber         = CAST(ISNULL(td.ReferenceNumber, '') AS varchar(50)),
            ReferenceKey            = CAST(ISNULL(td.ReferenceKey, '') AS varchar(50)),
            AccountCode             = CAST(td.AccountCode AS varchar(20)),
            AccountName             = CAST(ISNULL(coa.Description, '') AS varchar(256)),
            AccountType             = CAST(ISNULL(coa.AccountType, '') AS varchar(5)),
            Debit                   = CAST(td.Debit AS decimal(18,2)),
            Credit                  = CAST(td.Credit AS decimal(18,2)),
            Particulars             = CAST(ISNULL(td.Particulars, '') AS varchar(400)),
            WouldEnterGLIfHeadered  = CAST(CASE WHEN coa.AccountType = 'D' THEN 1 ELSE 0 END AS bit),
            RowSignedAmount         = CAST(CASE WHEN coa.AccountType <> 'D' THEN NULL
                                                 ELSE CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit
                                                                       ELSE          td.Credit - td.Debit END
                                            END AS decimal(18,2)),
            DirectionVsGap          = CAST(CASE
                                                WHEN coa.AccountType <> 'D' THEN 'N/A - NOT A DETAIL ACCOUNT'
                                                WHEN @ARGap12 = 0 THEN 'N/A - NO GAP TO CLOSE'
                                                WHEN SIGN(CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END) = SIGN(@ARGap12)
                                                    THEN 'TOWARD ZERO'
                                                ELSE 'AWAY FROM ZERO'
                                           END AS varchar(30)),
            PctOfGap                = CAST(CASE WHEN coa.AccountType <> 'D' OR @ARGap12 = 0 THEN NULL
                                                 ELSE (CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END)
                                                      / @ARGap12 * 100
                                            END AS decimal(9,2)),
            Note                    = CAST(CASE
                WHEN coa.AccountType <> 'D' OR @ARGap12 = 0
                    THEN 'CANDIDATE ONLY - not a postable detail account or no gap to evaluate against. See result set 1 for the authoritative reconciliation.'
                WHEN ABS(ABS((CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END) / @ARGap12 * 100) - 100) <= 15
                    THEN 'CANDIDATE, close to 100% of the gap - worth investigating first. Still unproven on its own: do NOT sum PctOfGap across rows, and headering this row may not close the gap. See result set 1 for the authoritative reconciliation.'
                ELSE 'UNLIKELY CANDIDATE - this row''s PctOfGap is far from 100%, so it is unlikely alone to be the gap''s cause even though its direction matches. Do NOT sum PctOfGap across rows to judge combined effect. See result set 1 for the authoritative reconciliation.'
            END AS varchar(500))
        FROM dbo.TicketDetails AS td
        LEFT JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
        WHERE td.TicketDate < @AsOfEnd
          AND EXISTS (SELECT 1 FROM dbo.vw_AccountTree AS t
                      WHERE t.AccountCode = td.AccountCode AND t.AncestorCode = '101030101')
          AND NOT EXISTS (
                SELECT 1 FROM dbo.TicketMaster AS tm
                WHERE tm.TicketDate          = td.TicketDate
                  AND tm.SupplementaryNumber = td.SupplementaryNumber
                  AND tm.BranchCode          = td.BranchCode
                  AND tm.TicketNumber        = td.TicketNumber)
        ORDER BY ABS(CASE WHEN coa.AccountType = 'D'
                          THEN CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END
                          ELSE (td.Debit + td.Credit) END) DESC;
        RETURN;
    END

    IF @Seq = 13
    BEGIN
        /* Combined (Trade+Expense) subledger definition, adopted 2026-09-12
           — see sp_rpt_DataHealthCheck Seq 13 comment and sql/09-apexp-aging.sql
           header for the investigation and numbers. @APGL13 (the GL side) is
           unchanged from the prior version of this check. */
        DECLARE @APSubledger13 decimal(18,2) = (SELECT ISNULL(SUM(Balance), 0)
                                                 FROM dbo.APAccounts WHERE Balance > 0)
                                              + (SELECT ISNULL(SUM(Balance), 0)
                                                 FROM dbo.ExpenseSummary WHERE Balance > 0);
        DECLARE @APGL13 decimal(18,2) = (
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
        DECLARE @APGap13 decimal(18,2) = @APSubledger13 - @APGL13;   -- signed: + => subledger > GL

        SELECT
            Seq            = CAST(13 AS int),
            CheckName      = CAST('AP (Trade+Expense) subledger vs GL 20101/20102/20103 tie-out gap' AS varchar(80)),
            AsOfDate       = CAST(@AsOfDate AS date),
            SubledgerTotal = CAST(@APSubledger13 AS decimal(18,2)),
            GLTotal        = CAST(@APGL13 AS decimal(18,2)),
            Gap            = CAST(@APGap13 AS decimal(18,2)),
            AbsGap         = CAST(ABS(@APGap13) AS decimal(18,2)),
            GapDirection   = CAST(CASE WHEN @APGap13 > 0 THEN 'SUBLEDGER EXCEEDS GL'
                                        WHEN @APGap13 < 0 THEN 'GL EXCEEDS SUBLEDGER'
                                        ELSE 'TIED OUT' END AS varchar(30));

        /* Residual blind spots — the "ExpenseSummary isn't included in this
           comparison" line from the pre-2026-09-12 version of this check is
           REMOVED here: that gap is now closed (SubledgerTotal above sums
           both APAccounts and ExpenseSummary). Everything below still
           genuinely applies to the combined figure. */
        /* accounting-reviewer's finding (2026-09-12): combining the two
           subledgers is mathematically sound (zero overlap on SupplierID+
           InvoiceNo, confirmed), but a single blended gap can hide that the
           two subledgers are NOT similarly broken — computed live below,
           not hardcoded, so this stays accurate as balances change. */
        DECLARE @APTradeShare decimal(9,2) = CASE WHEN @APGap13 = 0 THEN NULL
            ELSE (SELECT ISNULL(SUM(Balance),0) FROM dbo.APAccounts WHERE Balance > 0) / @APGap13 * 100 END;
        DECLARE @APExpShare decimal(9,2) = CASE WHEN @APGap13 = 0 THEN NULL
            ELSE (SELECT ISNULL(SUM(Balance),0) FROM dbo.ExpenseSummary WHERE Balance > 0) / @APGap13 * 100 END;

        SELECT BlindSpot = CAST(x.v AS varchar(400)) FROM (VALUES
            ('A posted/headered ticket booked to the WRONG account (miscoded to a different account, including a different control account) is invisible here: it has a TicketMaster row, so it nets straight into GLTotal above with no discrepancy flagged, and will never appear in the candidate list below.'),
            ('A Status value typo or unexpected value (anything not exactly POSTED or UPDATED) silently drops that ticket''s lines from GLTotal with no error. The ticket still has a TicketMaster row, so it is not an orphan and will not appear below.'),
            ('A subledger-side data error — an APAccounts OR ExpenseSummary row with no TicketDetails counterpart at all (e.g. a manual balance adjustment made directly on the subledger table) changes SubledgerTotal above with zero footprint in TicketDetails. There is no detail row to surface as a candidate.'),
            ('AsOfDate vs. live snapshot: both APAccounts.Balance and ExpenseSummary.Balance are CURRENT point-in-time balances (no history table for either). SubledgerTotal above always reflects TODAY''s combined balance regardless of @AsOfDate, while GLTotal is correctly bounded by @AsOfDate. A stale @AsOfDate can produce or mask a gap unrelated to any row below.'),
            ('This is a BLENDED gap across two subledgers with very different severity, not an equal split: AP-Trade (APAccounts) alone accounts for ' + CAST(ISNULL(@APTradeShare,0) AS varchar(20)) + '% of this gap, AP-Expense (ExpenseSummary) alone accounts for ' + CAST(ISNULL(@APExpShare,0) AS varchar(20)) + '%. A high AP-Trade share typically means AP-Trade has little or no posted GL footprint of its own in this account family (a structural disconnect), while AP-Expense''s share is more often an ordinary posting-timing lag. Do not read one combined number as "both subledgers are equally off."')
        ) AS x(v);

        SELECT TOP (500)
            TicketDate              = CAST(td.TicketDate AS date),
            BranchCode              = CAST(td.BranchCode AS varchar(5)),
            TicketNumber            = CAST(td.TicketNumber AS varchar(50)),
            SupplementaryNumber     = CAST(td.SupplementaryNumber AS tinyint),
            ReferenceNumber         = CAST(ISNULL(td.ReferenceNumber, '') AS varchar(50)),
            ReferenceKey            = CAST(ISNULL(td.ReferenceKey, '') AS varchar(50)),
            AccountCode             = CAST(td.AccountCode AS varchar(20)),
            AccountName             = CAST(ISNULL(coa.Description, '') AS varchar(256)),
            AccountType             = CAST(ISNULL(coa.AccountType, '') AS varchar(5)),
            Debit                   = CAST(td.Debit AS decimal(18,2)),
            Credit                  = CAST(td.Credit AS decimal(18,2)),
            Particulars             = CAST(ISNULL(td.Particulars, '') AS varchar(400)),
            WouldEnterGLIfHeadered  = CAST(CASE WHEN coa.AccountType = 'D' THEN 1 ELSE 0 END AS bit),
            RowSignedAmount         = CAST(CASE WHEN coa.AccountType <> 'D' THEN NULL
                                                 ELSE CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit
                                                                       ELSE          td.Credit - td.Debit END
                                            END AS decimal(18,2)),
            DirectionVsGap          = CAST(CASE
                                                WHEN coa.AccountType <> 'D' THEN 'N/A - NOT A DETAIL ACCOUNT'
                                                WHEN @APGap13 = 0 THEN 'N/A - NO GAP TO CLOSE'
                                                WHEN SIGN(CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END) = SIGN(@APGap13)
                                                    THEN 'TOWARD ZERO'
                                                ELSE 'AWAY FROM ZERO'
                                           END AS varchar(30)),
            PctOfGap                = CAST(CASE WHEN coa.AccountType <> 'D' OR @APGap13 = 0 THEN NULL
                                                 ELSE (CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END)
                                                      / @APGap13 * 100
                                            END AS decimal(9,2)),
            Note                    = CAST(CASE
                WHEN coa.AccountType <> 'D' OR @APGap13 = 0
                    THEN 'CANDIDATE ONLY - not a postable detail account or no gap to evaluate against. See result set 1 for the authoritative reconciliation.'
                WHEN ABS(ABS((CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END) / @APGap13 * 100) - 100) <= 15
                    THEN 'CANDIDATE, close to 100% of the gap - worth investigating first. Still unproven on its own: do NOT sum PctOfGap across rows, and headering this row may not close the gap. See result set 1 for the authoritative reconciliation.'
                ELSE 'UNLIKELY CANDIDATE - this row''s PctOfGap is far from 100%, so it is unlikely alone to be the gap''s cause even though its direction matches. Do NOT sum PctOfGap across rows to judge combined effect. See result set 1 for the authoritative reconciliation.'
            END AS varchar(500))
        FROM dbo.TicketDetails AS td
        LEFT JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
        WHERE td.TicketDate < @AsOfEnd
          AND EXISTS (SELECT 1 FROM dbo.vw_AccountTree AS t
                      WHERE t.AccountCode = td.AccountCode AND t.AncestorCode IN ('20101','20102','20103'))
          AND NOT EXISTS (
                SELECT 1 FROM dbo.TicketMaster AS tm
                WHERE tm.TicketDate          = td.TicketDate
                  AND tm.SupplementaryNumber = td.SupplementaryNumber
                  AND tm.BranchCode          = td.BranchCode
                  AND tm.TicketNumber        = td.TicketNumber)
        ORDER BY ABS(CASE WHEN coa.AccountType = 'D'
                          THEN CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END
                          ELSE (td.Debit + td.Credit) END) DESC;
        RETURN;
    END

    /* ==== 14. AR items with negative Balance ==== */
    IF @Seq = 14
    BEGIN
        SELECT TOP (500)
            CustomerKey     = CAST(t.CustomerKey AS char(8)),
            CustomerName    = CAST(ISNULL(c.CustomerName, 'UNKNOWN CUSTOMER - ' + t.CustomerKey) AS varchar(200)),
            InvoiceNo       = CAST(ISNULL(t.InvoiceNo, '') AS varchar(100)),
            ReferenceNo     = CAST(ISNULL(t.ReferenceNo, '') AS varchar(20)),
            TransactionDate = CAST(t.TransactionDate AS date),
            Balance         = CAST(t.Balance AS decimal(18,2)),
            PayStatus       = CAST(ISNULL(t.PayStatus, '') AS varchar(10))
        FROM dbo.TransactionChargeSales AS t
        LEFT JOIN dbo.Customers AS c ON c.CustomerKey = t.CustomerKey
        WHERE t.Balance < 0
        ORDER BY t.Balance ASC;
        RETURN;
    END

    /* ==== 15. AP items with negative Balance ==== */
    IF @Seq = 15
    BEGIN
        SELECT TOP (500)
            SupplierID      = CAST(a.SupplierID AS varchar(30)),
            SupplierName    = CAST(ISNULL(s.SupplierName, 'UNKNOWN SUPPLIER - ' + a.SupplierID) AS varchar(300)),
            InvoiceNo       = CAST(ISNULL(a.InvoiceNo, '') AS varchar(80)),
            ReferenceNumber = CAST(ISNULL(a.ReferenceNumber, '') AS char(5)),
            InvoiceDate     = CAST(a.InvoiceDate AS date),
            Balance         = CAST(a.Balance AS decimal(18,2)),
            PayStatus       = CAST(ISNULL(a.PayStatus, '') AS varchar(20))
        FROM dbo.APAccounts AS a
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = a.SupplierID
        WHERE a.Balance < 0
        ORDER BY a.Balance ASC;
        RETURN;
    END

    /* ==== 16. AP-EXP open items with unaged date ==== */
    IF @Seq = 16
    BEGIN
        SELECT TOP (500)
            SupplierID      = CAST(e.SupplierID AS varchar(30)),
            SupplierName    = CAST(ISNULL(s.SupplierName, 'UNKNOWN SUPPLIER - ' + e.SupplierID) AS varchar(300)),
            InvoiceNo       = CAST(ISNULL(e.InvoiceNo, '') AS varchar(150)),
            ReferenceNumber = CAST(ISNULL(e.ReferenceNumber, '') AS varchar(10)),
            ExpenseDate     = CAST(e.ExpenseDate AS date),
            Balance         = CAST(e.Balance AS decimal(18,2)),
            Status          = CAST(ISNULL(e.Status, '') AS varchar(50))
        FROM dbo.ExpenseSummary AS e
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = e.SupplierID
        WHERE e.Balance > 0
          AND (e.ExpenseDate IS NULL OR e.ExpenseDate > @AsOfDate)
        ORDER BY e.Balance DESC;
        RETURN;
    END

    /* ==== 17. AP-EXP open items with unknown SupplierID ==== */
    IF @Seq = 17
    BEGIN
        SELECT TOP (500)
            SupplierID      = CAST(e.SupplierID AS varchar(30)),
            InvoiceNo       = CAST(ISNULL(e.InvoiceNo, '') AS varchar(150)),
            ReferenceNumber = CAST(ISNULL(e.ReferenceNumber, '') AS varchar(10)),
            ExpenseDate     = CAST(e.ExpenseDate AS date),
            Balance         = CAST(e.Balance AS decimal(18,2)),
            Status          = CAST(ISNULL(e.Status, '') AS varchar(50))
        FROM dbo.ExpenseSummary AS e
        WHERE e.Balance > 0
          AND NOT EXISTS (SELECT 1 FROM dbo.Supplier AS s WHERE s.SupplierID = e.SupplierID)
        ORDER BY e.Balance DESC;
        RETURN;
    END

    /* ==== 18. AP-EXP items with negative Balance ==== */
    IF @Seq = 18
    BEGIN
        SELECT TOP (500)
            SupplierID      = CAST(e.SupplierID AS varchar(30)),
            SupplierName    = CAST(ISNULL(s.SupplierName, 'UNKNOWN SUPPLIER - ' + e.SupplierID) AS varchar(300)),
            InvoiceNo       = CAST(ISNULL(e.InvoiceNo, '') AS varchar(150)),
            ReferenceNumber = CAST(ISNULL(e.ReferenceNumber, '') AS varchar(10)),
            ExpenseDate     = CAST(e.ExpenseDate AS date),
            Balance         = CAST(e.Balance AS decimal(18,2)),
            Status          = CAST(ISNULL(e.Status, '') AS varchar(50))
        FROM dbo.ExpenseSummary AS e
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = e.SupplierID
        WHERE e.Balance < 0
        ORDER BY e.Balance ASC;
        RETURN;
    END

    /* ==== Unknown @Seq — fail loudly rather than silently return nothing ==== */
    RAISERROR('sp_rpt_DataHealthCheckDetail: unknown @Seq value %d (expected 1-18).', 16, 1, @Seq);
END
GO


/* ============================================================================
   SMOKE TEST
============================================================================ */
/*
EXEC dbo.sp_rpt_APEXP_Aging @AsOfDate = '2026-09-12';

-- Bug-2-style regression check: an @AsOfDate that predates all ExpenseDate
-- values must still return a TOTAL rollup row of 0.00s, never NULLs.
EXEC dbo.sp_rpt_APEXP_Aging @AsOfDate = '1900-01-01';

DECLARE @From date = '2026-07-01', @To date = '2026-09-12';

EXEC dbo.sp_rpt_DataHealthCheck @DateFrom = @From, @DateTo = @To;

-- Check 13 regression check (combined Trade+Expense subledger, 2026-09-12
-- redefinition): confirm SubledgerTotal = APAccounts.Balance sum +
-- ExpenseSummary.Balance sum, and Gap widens accordingly vs the pre-change
-- APAccounts-only figure.
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 13, @DateFrom = @From, @DateTo = @To;

EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 16, @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 17, @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 18, @DateFrom = @From, @DateTo = @To;

-- Fails loudly, does not silently return empty:
-- EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 99, @DateFrom = @From, @DateTo = @To;
*/
