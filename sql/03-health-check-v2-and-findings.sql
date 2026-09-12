/* ============================================================================
   CORE REPORTING PORTAL — HEALTH CHECK v2 + FINDINGS DRILL-DOWN

   Supersedes SECTION 5 of 01-exec-overview-data-layer.sql.
   Run SECTION A and B first (they are safe, structural), then C to
   investigate the two live defects.
============================================================================ */


/* ============================================================================
   SECTION A — COMPLETE THE MNEMONIC MAP

   The nine unmapped mnemonics are all from modules built after the list was
   drawn up. Two of them are cross-branch by design and get a flag of their
   own so the health check stops reporting them as broken.
============================================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.RptMnemonicMap')
                 AND name = 'IsCrossBranch')
BEGIN
    ALTER TABLE dbo.RptMnemonicMap
        ADD IsCrossBranch bit NOT NULL CONSTRAINT DF_RptMnemonicMap_XBr DEFAULT (0);
END
GO

MERGE dbo.RptMnemonicMap AS tgt
USING (VALUES
    /* Mnemonic,                Family,       Description,                                          Internal, CrossBranch */
    ('SINGLE',                  'EXPENSE',    'Single-mode expense posting (manual GL, no mapping)',        0, 0),
    ('SINGLE-PAY',              'PAYMENT',    'Single-mode expense payment',                                0, 0),
    ('CASH ADVANCE',            'PAYMENT',    'Cash advance vouchering',                                    0, 0),
    ('VOUCHER-MANUAL',          'PAYMENT',    'Manual vouchering - free-form GL entry',                     0, 0),
    ('MANUAL-DEBIT-IN-PAYMENT', 'PAYMENT',    'Manual debit line inside a supplier payment voucher',        0, 0),
    ('MANUAL JV',               'JOURNAL',    'Manual journal voucher - single branch',                     0, 0),
    ('MANUAL JV - MULTI-BR',    'JOURNAL',    'Manual journal voucher - multi-branch, balances per branch', 0, 0),
    /* --- balance across the ReferenceNumber set, not per ticket --------- */
    ('MANUAL JV - CROSS-BR',    'JOURNAL',    'Manual journal voucher - cross-branch',                      0, 1),
    ('EXP-MANUAL-CROSS-BR',     'EXPENSE',    'Multi-branch manual expense - cross-branch',                 0, 1)
) AS src (Mnemonic, Family, Description, IsInternal, IsCrossBranch)
ON tgt.Mnemonic = src.Mnemonic
WHEN MATCHED THEN
    UPDATE SET Family = src.Family, Description = src.Description,
               IsInternal = src.IsInternal, IsCrossBranch = src.IsCrossBranch
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Mnemonic, Family, Description, IsInternal, IsCrossBranch)
    VALUES (src.Mnemonic, src.Family, src.Description, src.IsInternal, src.IsCrossBranch);
GO

/*  NOTE — the one NULL mnemonic is your 'BeginningBalance Forward' entry
    from 2026-06-01. It cannot be mapped (NULL is not a key) and it does not
    need to be: opening balances must be included in every balance sheet
    figure, and nothing in the reporting layer filters BS accounts by
    mnemonic. Leave it alone. The health check below ignores NULL mnemonics
    for the same reason.                                                    */


/* ============================================================================
   SECTION B — HEALTH CHECK v2

   Changes from v1:
     - Cross-branch mnemonics are tested across the ReferenceNumber set
       instead of per ticket. This is what your modules actually guarantee.
     - Summary-account postings now report the value at risk, not just a count.
     - Unknown-account rows report the value that is invisible to reporting.
============================================================================ */

IF OBJECT_ID('dbo.sp_rpt_DataHealthCheck', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_DataHealthCheck;
GO

CREATE PROCEDURE dbo.sp_rpt_DataHealthCheck
    @DateFrom date,
    @DateTo   date
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @Start datetime = CAST(@DateFrom AS datetime);

    CREATE TABLE #Result
    (
        Seq        int,
        CheckName  varchar(60),
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

    SELECT CheckName, Severity, Findings, ValueAtRisk
    FROM #Result
    ORDER BY Seq;

    DROP TABLE #Result;
END
GO


/* ============================================================================
   SECTION C — DRILL INTO THE TWO LIVE DEFECTS
============================================================================ */

/* ----------------------------------------------------------------------------
   C1 — THE TWO UNBALANCED PV-AP VOUCHERS, LINE BY LINE

   Ref 9475  ticket 1742  Dr 1,824,830.00  Cr 1,826,140.00  var -1,310.00
   Ref 9877  ticket 2181  Dr 1,055,000.00  Cr 1,110,000.00  var -55,000.00

   Both are Head Office, both 3 lines, both credit-heavy. On ref 9877 the
   variance is exactly 5% of 1,100,000 — the signature of a withholding leg
   where the AP debit was booked net instead of gross.
---------------------------------------------------------------------------- */
SELECT
    tm.ReferenceNumber,
    tm.TicketNumber,
    tm.TicketDate,
    tm.BranchCode,
    tm.Mnemonic,
    td.AccountCode,
    AccountName = coa.Description,
    coa.Nature,
    td.Debit,
    td.Credit,
    td.ReferenceKey,
    td.Particulars,
    tm.Owner,
    tm.Particulars AS HeaderParticulars
FROM dbo.TicketMaster AS tm
INNER JOIN dbo.TicketDetails AS td
    ON  td.TicketDate          = tm.TicketDate
    AND td.SupplementaryNumber = tm.SupplementaryNumber
    AND td.BranchCode          = tm.BranchCode
    AND td.TicketNumber        = tm.TicketNumber
LEFT JOIN dbo.ChartOfAccounts AS coa
    ON coa.AccountCode = td.AccountCode
WHERE tm.ReferenceNumber IN ('9475', '9877')
ORDER BY tm.ReferenceNumber, td.AccountCode;


/* ----------------------------------------------------------------------------
   C2 — ACCOUNT 40510: 1.7 MILLION POSTING TO AN ACCOUNT THAT DOES NOT EXIST

   Seven rows, all credits, ₱1,708,403.55, all mnemonic SINGLE-PAY, all
   within three days. No whitespace variant exists, so this is not a typo in
   the data — it is a hardcoded account code in whichever procedure posts
   SINGLE-PAY.

   These tickets balance in raw debits and credits, which is why they did not
   appear in the unbalanced check. But because 40510 is not in the chart, the
   credit side is invisible to every rollup: the debit is counted, the credit
   is not. Every report touching those periods is overstated by up to 1.7M.

   This query shows the full ticket around each of the seven rows, so you can
   see what the leg was meant to be.
---------------------------------------------------------------------------- */
;WITH BadTickets AS
(
    SELECT DISTINCT td.TicketDate, td.SupplementaryNumber,
                    td.BranchCode, td.TicketNumber
    FROM dbo.TicketDetails AS td
    WHERE td.AccountCode = '40510'
)
SELECT
    tm.ReferenceNumber,
    tm.TicketNumber,
    tm.TicketDate,
    tm.BranchCode,
    tm.Mnemonic,
    td.AccountCode,
    AccountName = ISNULL(coa.Description, '*** NOT IN CHART ***'),
    td.Debit,
    td.Credit,
    td.Particulars,
    tm.Owner,
    tm.EnteredBy
FROM BadTickets AS b
INNER JOIN dbo.TicketMaster AS tm
    ON  tm.TicketDate          = b.TicketDate
    AND tm.SupplementaryNumber = b.SupplementaryNumber
    AND tm.BranchCode          = b.BranchCode
    AND tm.TicketNumber        = b.TicketNumber
INNER JOIN dbo.TicketDetails AS td
    ON  td.TicketDate          = tm.TicketDate
    AND td.SupplementaryNumber = tm.SupplementaryNumber
    AND td.BranchCode          = tm.BranchCode
    AND td.TicketNumber        = tm.TicketNumber
LEFT JOIN dbo.ChartOfAccounts AS coa
    ON coa.AccountCode = td.AccountCode
ORDER BY tm.ReferenceNumber, td.AccountCode;


/* ----------------------------------------------------------------------------
   C3 — FIND THE HARDCODED '40510' IN YOUR PROCEDURE SOURCE
   Run this and it will name the procedure to fix.
---------------------------------------------------------------------------- */
SELECT
    ObjectName = OBJECT_SCHEMA_NAME(sm.object_id) + '.' + OBJECT_NAME(sm.object_id),
    ObjectType = o.type_desc,
    Modified   = o.modify_date
FROM sys.sql_modules AS sm
INNER JOIN sys.objects AS o ON o.object_id = sm.object_id
WHERE sm.definition LIKE '%40510%'
ORDER BY o.modify_date DESC;

/* Same sweep for every account code used in code but absent from the chart */
SELECT DISTINCT
    td.AccountCode,
    UsedInObjects = (SELECT COUNT(*) FROM sys.sql_modules AS sm
                     WHERE sm.definition LIKE '%' + td.AccountCode + '%')
FROM dbo.TicketDetails AS td
WHERE NOT EXISTS (SELECT 1 FROM dbo.ChartOfAccounts AS coa
                  WHERE coa.AccountCode = td.AccountCode);


/* ----------------------------------------------------------------------------
   C4 — BRANCH 013
   Postings exist for branch 013 but it is not in the branch master. It is
   not the display-text truncation bug this time: the code is clean, the
   master row is simply missing.
---------------------------------------------------------------------------- */
SELECT
    tm.BranchCode,
    Tickets   = COUNT(DISTINCT tm.TicketNumber),
    Mnemonics = STRING_AGG(CONVERT(varchar(50), tm.Mnemonic), ', '),
    FirstSeen = MIN(tm.TicketDate),
    LastSeen  = MAX(tm.TicketDate),
    Users     = STRING_AGG(CONVERT(varchar(128), tm.EnteredBy), ', ')
FROM dbo.TicketMaster AS tm
WHERE NOT EXISTS (SELECT 1 FROM dbo.Branches AS b WHERE b.BranchCode = tm.BranchCode)
GROUP BY tm.BranchCode;

/*  If 013 is a real branch, add it to dbo.Branches and it will appear on the
    scorecard immediately. If it is test data, the tickets should be reversed
    rather than deleted — sp_rpt_Exec_BranchScorecard joins FROM dbo.Branches,
    so until the master row exists, 013's activity is silently dropped from
    every branch report while still counting in the company totals. That
    mismatch is worse than either fix.                                      */


/* ----------------------------------------------------------------------------
   C5 — THE SUMMARY-ACCOUNT POSTING
   One row: ₱1.00 to 10102 CASH IN BANK, mnemonic EXP-MANUAL-CROSS-BR,
   ref 10312, entered by 'systeadmin'. Its counterpart (ticket 2613, branch
   006, credit 1.00) nets the set to zero, so this is a one-peso test entry.

   Worth fixing anyway, for one reason: 10102 is a summary node whose
   children are also summary nodes (1010201 local, 1010202 foreign). There is
   no valid detail account directly beneath it, which is why SuggestedDetail
   came back NULL. A posting there is counted at the node and again through
   the subtree, so it double-counts cash on every report that rolls up.

   The durable fix is server side: block postings to AccountType 'S' at the
   point of posting rather than catching them here. This confirms the gap
   exists in whichever procedure posts EXP-MANUAL-CROSS-BR.
---------------------------------------------------------------------------- */
SELECT
    coa.AccountCode, coa.Description, coa.AccountType, coa.LevelNumber,
    ChildCount       = (SELECT COUNT(*) FROM dbo.ChartOfAccounts AS c
                        WHERE c.SummaryAccount = coa.AccountCode),
    PostableChildren = (SELECT COUNT(*) FROM dbo.ChartOfAccounts AS c
                        WHERE c.SummaryAccount = coa.AccountCode AND c.AccountType = 'D')
FROM dbo.ChartOfAccounts AS coa
WHERE coa.AccountCode = '10102';
