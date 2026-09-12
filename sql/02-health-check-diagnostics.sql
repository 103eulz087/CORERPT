/* ============================================================================
   CORE REPORTING PORTAL — HEALTH CHECK DIAGNOSTICS
   Run each query, keep the output. Findings and fixes are noted inline.
   Nothing here modifies data. The one UPDATE is commented out.
============================================================================ */

DECLARE @DateFrom date = '2020-01-01';   -- widen to cover all history
DECLARE @DateTo   date = '2026-12-31';
DECLARE @Start datetime = CAST(@DateFrom AS datetime);
DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));


/* ============================================================================
   Q1 — THE 68 UNBALANCED TICKETS, PER TICKET
   Expect most of these to carry a multi-branch mnemonic. If so, see Q1b.
============================================================================ */
SELECT
    tm.Mnemonic,
    tm.TicketDate,
    tm.BranchCode,
    tm.TicketNumber,
    tm.ReferenceNumber,
    tm.Status,
    TotalDebit  = SUM(td.Debit),
    TotalCredit = SUM(td.Credit),
    Variance    = SUM(td.Debit) - SUM(td.Credit),
    LineCount   = COUNT(*),
    tm.EnteredBy
FROM dbo.TicketDetails AS td
INNER JOIN dbo.TicketMaster AS tm
    ON  tm.TicketDate          = td.TicketDate
    AND tm.SupplementaryNumber = td.SupplementaryNumber
    AND tm.BranchCode          = td.BranchCode
    AND tm.TicketNumber        = td.TicketNumber
WHERE tm.Status IN ('POSTED','UPDATED')
  AND td.TicketDate >= @Start AND td.TicketDate < @End
GROUP BY tm.Mnemonic, tm.TicketDate, tm.BranchCode, tm.TicketNumber,
         tm.ReferenceNumber, tm.Status, tm.EnteredBy
HAVING SUM(td.Debit) <> SUM(td.Credit)
ORDER BY tm.Mnemonic, tm.TicketDate;


/* ============================================================================
   Q1b — DO THEY BALANCE AS A SET?
   Regroups the same tickets by ReferenceNumber instead of by ticket. This is
   the test that matches how your multi-branch modules actually post.

   Rows returned here are genuinely broken.
   Rows that vanish between Q1 and Q1b were cross-branch by design.
============================================================================ */
;WITH Bad AS
(
    SELECT tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode,
           tm.TicketNumber, tm.ReferenceNumber, tm.Mnemonic
    FROM dbo.TicketDetails AS td
    INNER JOIN dbo.TicketMaster AS tm
        ON  tm.TicketDate          = td.TicketDate
        AND tm.SupplementaryNumber = td.SupplementaryNumber
        AND tm.BranchCode          = td.BranchCode
        AND tm.TicketNumber        = td.TicketNumber
    WHERE tm.Status IN ('POSTED','UPDATED')
      AND td.TicketDate >= @Start AND td.TicketDate < @End
    GROUP BY tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode,
             tm.TicketNumber, tm.ReferenceNumber, tm.Mnemonic
    HAVING SUM(td.Debit) <> SUM(td.Credit)
)
SELECT
    b.ReferenceNumber,
    Mnemonics      = STRING_AGG(DISTINCT_M.Mnemonic, ' | '),
    BranchesInSet  = COUNT(DISTINCT tm.BranchCode),
    TicketsInSet   = COUNT(DISTINCT tm.TicketNumber),
    SetDebit       = SUM(td.Debit),
    SetCredit      = SUM(td.Credit),
    SetVariance    = SUM(td.Debit) - SUM(td.Credit)
FROM (SELECT DISTINCT ReferenceNumber FROM Bad) AS b
INNER JOIN dbo.TicketMaster AS tm
    ON tm.ReferenceNumber = b.ReferenceNumber
INNER JOIN dbo.TicketDetails AS td
    ON  td.TicketDate          = tm.TicketDate
    AND td.SupplementaryNumber = tm.SupplementaryNumber
    AND td.BranchCode          = tm.BranchCode
    AND td.TicketNumber        = tm.TicketNumber
CROSS APPLY (SELECT Mnemonic = tm.Mnemonic) AS DISTINCT_M
WHERE tm.Status IN ('POSTED','UPDATED')
GROUP BY b.ReferenceNumber
HAVING SUM(td.Debit) <> SUM(td.Credit)      -- only sets that still don't tie
ORDER BY ABS(SUM(td.Debit) - SUM(td.Credit)) DESC;


/* ============================================================================
   Q2 — THE POSTING TO A SUMMARY ACCOUNT
   Summary accounts are rollup nodes. A posting here is counted once at the
   node and again through its children, so it double-counts every report
   that touches that branch of the tree.
============================================================================ */
SELECT
    td.AccountCode,
    coa.Description,
    coa.AccountType,
    coa.LevelNumber,
    tm.Mnemonic,
    tm.TicketDate,
    tm.BranchCode,
    tm.TicketNumber,
    tm.ReferenceNumber,
    td.Debit,
    td.Credit,
    td.Particulars,
    tm.EnteredBy,
    /* Suggested destination: a detail account directly under this node */
    SuggestedDetail = (SELECT TOP 1 c2.AccountCode + ' - ' + c2.Description
                       FROM dbo.ChartOfAccounts AS c2
                       WHERE c2.SummaryAccount = coa.AccountCode
                         AND c2.AccountType = 'D'
                       ORDER BY c2.AccountCode)
FROM dbo.TicketDetails AS td
INNER JOIN dbo.TicketMaster AS tm
    ON  tm.TicketDate          = td.TicketDate
    AND tm.SupplementaryNumber = td.SupplementaryNumber
    AND tm.BranchCode          = td.BranchCode
    AND tm.TicketNumber        = td.TicketNumber
INNER JOIN dbo.ChartOfAccounts AS coa
    ON coa.AccountCode = td.AccountCode
WHERE coa.AccountType = 'S'
  AND td.TicketDate >= @Start AND td.TicketDate < @End;


/* ============================================================================
   Q3 — THE 7 UNKNOWN ACCOUNT CODES
   These post to codes that are not in the chart at all, so they are invisible
   to every rollup: they contribute to no total, yet they are half of a real
   double entry. This is very likely part of the 68 in Q1.

   Most common causes, in order:
     a) accounts you deleted from the chart that still have history
     b) trailing whitespace or a case difference in the code
     c) a hardcoded account code in an old stored procedure
============================================================================ */
SELECT
    td.AccountCode,
    CodeLength      = LEN(td.AccountCode),
    HasTrailingSpace= CASE WHEN td.AccountCode <> LTRIM(RTRIM(td.AccountCode))
                           THEN 'YES' ELSE 'no' END,
    Rows            = COUNT(*),
    TotalDebit      = SUM(td.Debit),
    TotalCredit     = SUM(td.Credit),
    FirstSeen       = MIN(td.TicketDate),
    LastSeen        = MAX(td.TicketDate),
    Mnemonics       = STRING_AGG(CONVERT(varchar(50), tm.Mnemonic), ', '),
    SampleParticular= MIN(td.Particulars),
    /* Does a trimmed version exist in the chart? Then it is (b), not (a). */
    TrimmedMatchExists = CASE WHEN EXISTS (
                             SELECT 1 FROM dbo.ChartOfAccounts AS c
                             WHERE c.AccountCode = LTRIM(RTRIM(td.AccountCode)))
                         THEN 'YES - whitespace issue' ELSE 'no' END
FROM dbo.TicketDetails AS td
LEFT JOIN dbo.TicketMaster AS tm
    ON  tm.TicketDate          = td.TicketDate
    AND tm.SupplementaryNumber = td.SupplementaryNumber
    AND tm.BranchCode          = td.BranchCode
    AND tm.TicketNumber        = td.TicketNumber
WHERE td.TicketDate >= @Start AND td.TicketDate < @End
  AND NOT EXISTS (SELECT 1 FROM dbo.ChartOfAccounts AS coa
                  WHERE coa.AccountCode = td.AccountCode)
GROUP BY td.AccountCode
ORDER BY SUM(td.Debit + td.Credit) DESC;


/* ============================================================================
   Q4 — THE 9 UNMAPPED MNEMONICS
   Almost certainly the module mnemonics that were not in the list you sent:
   MANUAL JV, MANUAL JV - CROSS-BR, VOUCHER-MANUAL, and similar.
   Send me this output and I will add them to RptMnemonicMap.
============================================================================ */
SELECT
    tm.Mnemonic,
    Tickets    = COUNT(*),
    FirstSeen  = MIN(tm.TicketDate),
    LastSeen   = MAX(tm.TicketDate),
    Branches   = COUNT(DISTINCT tm.BranchCode),
    SampleParticulars = MIN(CONVERT(varchar(200), tm.Particulars))
FROM dbo.TicketMaster AS tm
WHERE tm.TicketDate >= @Start AND tm.TicketDate < @End
  AND tm.Status IN ('POSTED','UPDATED')
  AND tm.Mnemonic IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM dbo.RptMnemonicMap AS mm
                  WHERE mm.Mnemonic = tm.Mnemonic)
GROUP BY tm.Mnemonic
ORDER BY COUNT(*) DESC;


/* ============================================================================
   Q5 — THE UNKNOWN BRANCH CODE
   Check for the combined display-text bug you have hit before: a value like
   '002-IL' stored where '002' belongs, truncated to varchar(5).
============================================================================ */
SELECT
    td.BranchCode,
    CodeLength   = LEN(td.BranchCode),
    LooksLikeDisplayText = CASE WHEN td.BranchCode LIKE '%-%' THEN 'YES' ELSE 'no' END,
    Rows         = COUNT(*),
    FirstSeen    = MIN(td.TicketDate),
    LastSeen     = MAX(td.TicketDate),
    Mnemonics    = STRING_AGG(CONVERT(varchar(50), tm.Mnemonic), ', ')
FROM dbo.TicketDetails AS td
LEFT JOIN dbo.TicketMaster AS tm
    ON  tm.TicketDate          = td.TicketDate
    AND tm.SupplementaryNumber = td.SupplementaryNumber
    AND tm.BranchCode          = td.BranchCode
    AND tm.TicketNumber        = td.TicketNumber
WHERE td.TicketDate >= @Start AND td.TicketDate < @End
  AND NOT EXISTS (SELECT 1 FROM dbo.Branches AS b
                  WHERE b.BranchCode = td.BranchCode)
GROUP BY td.BranchCode;

/* Same check on the master, in case only one side is wrong */
SELECT tm.BranchCode, Tickets = COUNT(*), FirstSeen = MIN(tm.TicketDate)
FROM dbo.TicketMaster AS tm
WHERE tm.TicketDate >= @Start AND tm.TicketDate < @End
  AND NOT EXISTS (SELECT 1 FROM dbo.Branches AS b WHERE b.BranchCode = tm.BranchCode)
GROUP BY tm.BranchCode;


/* ============================================================================
   REMEDIATION — READ BEFORE RUNNING ANYTHING BELOW

   Do NOT run these until the queries above tell you which cause applies.
   Take a backup first. These touch posted accounting records.
============================================================================ */

/* -- If Q3 shows 'YES - whitespace issue', this repairs those rows only.
      Everything else in Q3 needs the missing accounts restored to the chart
      instead, since deleting an account does not delete its history.

BEGIN TRAN;

    UPDATE td
       SET td.AccountCode = LTRIM(RTRIM(td.AccountCode))
    FROM dbo.TicketDetails AS td
    WHERE td.AccountCode <> LTRIM(RTRIM(td.AccountCode))
      AND EXISTS (SELECT 1 FROM dbo.ChartOfAccounts AS c
                  WHERE c.AccountCode = LTRIM(RTRIM(td.AccountCode)));

    -- Confirm the count matches Q3 before committing
    SELECT @@ROWCOUNT AS RowsRepaired;

-- ROLLBACK TRAN;
-- COMMIT TRAN;
*/
