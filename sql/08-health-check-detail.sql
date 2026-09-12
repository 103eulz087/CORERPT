/* ============================================================================
   CORE REPORTING PORTAL — HEALTH CHECK DRILL-DOWN (sp_rpt_DataHealthCheckDetail)
   Target: CORECSERP_002_DEV only (never staging without asking).

   Purpose: the Health Check page currently shows Findings/ValueAtRisk per
   check with no way to see the offending rows. This adds ONE generic proc,
   branching on @Seq (1-15, matching the Seq values already emitted by
   dbo.sp_rpt_DataHealthCheck), that returns the actual rows counted by that
   check's aggregate. Read-only. No base tables are written.

   ----------------------------------------------------------------------------
   VERIFICATION DONE BEFORE WRITING THIS FILE
   ----------------------------------------------------------------------------
   Read the LIVE definition of dbo.sp_rpt_DataHealthCheck on CORECSERP_002_DEV
   via OBJECT_DEFINITION() (not the checked-in .sql files) and confirmed it is
   byte-for-byte identical to the version in sql/05-accounting-aging.sql
   (checks 1-15, @DateFrom/@DateTo/@AsOfDate signature). The developer's
   paraphrase of checks 1-13 is accurate. Checks 14/15 read live as:
     14: SELECT ... FROM dbo.TransactionChargeSales WHERE Balance < 0   (no other predicate)
     15: SELECT ... FROM dbo.APAccounts             WHERE Balance < 0   (no other predicate)

   Also read INFORMATION_SCHEMA.COLUMNS live for TicketDetails, TicketMaster,
   ChartOfAccounts, RptMnemonicMap, Branches, TransactionChargeSales,
   APAccounts, Customers, Supplier, and vw_AccountTree. Notable facts that
   shaped the queries below:
     - TicketDetails carries its OWN ReferenceNumber and ReferenceKey columns
       (varchar(50) each), separate from TicketMaster's (varchar(150) each).
       This matters for check 3/12/13 (orphan rows): there is no TicketMaster
       row to join to, so TicketDetails' own Reference columns are the only
       ones available and are used instead.
     - Check 4 (postings to summary accounts) and check 5 (unknown account
       codes) do NOT join TicketMaster or filter by Status in the live proc —
       only check 4/5's TicketDetails+ChartOfAccounts predicate counts. The
       detail queries below preserve that: TicketMaster is LEFT JOINed only
       for display enrichment (Mnemonic, ReferenceNumber), never added to the
       WHERE clause, so the row set counted is unchanged.
     - vw_AccountTree exposes AccountCode, Description, AccountType,
       LevelNumber, Nature, AncestorCode, Depth — AncestorCode is what checks
       12/13 already use to identify the AR/AP control-account subtrees.
     - APAccounts has no branch column (confirmed already in
       05-accounting-aging.sql); AP-side detail views below carry no branch.

   ----------------------------------------------------------------------------
   ROW GRAIN PER CHECK (why some checks group and others don't)
   ----------------------------------------------------------------------------
   Checks 3, 4, 5, 7, 8, 9, 10, 11, 14, 15 — the underlying predicate already
   identifies individual offending rows (no GROUP BY in the aggregate check),
   so the detail view is a mechanical swap: same WHERE/NOT EXISTS, SELECT the
   row instead of COUNT/SUM'ing it.

   Check 1 — the aggregate check groups by the ticket's natural key
   (TicketDate, SupplementaryNumber, BranchCode, TicketNumber) and flags
   whole tickets via HAVING. The actionable "row" here is the ticket detail
   LINE, not the ticket-level variance: a person fixing this needs to see
   every debit/credit line of the broken ticket, exactly like the existing
   ad-hoc drill-down in sql/03-health-check-v2-and-findings.sql Section C1.
   So: reuse the identical GROUP BY/HAVING to identify the offending ticket
   keys (capped at the 200 largest-variance tickets), then join back to
   return every TicketDetails line for those tickets.

   Check 2 — same idea, but the developer's task explicitly asks for the
   grouped rows (one per offending ReferenceNumber), not line items, because
   a cross-branch set can span many tickets/branches and the ReferenceNumber
   is itself the actionable unit (that's what balances, per Hard Rule #6).

   Check 6 — grouped by Mnemonic per the developer's explicit instruction:
   one row per unmapped mnemonic, with an occurrence count and a couple of
   sample TicketNumbers, since the whole point is "which mnemonics need a
   RptMnemonicMap row", not a list of every ticket using them.

   Checks 12/13 (tie-out gaps) — REDESIGNED 2026-09-12, NOT a mechanical
   translation and NOT a single result set. Each returns THREE result sets:
   (1) the reconciliation itself (SubledgerTotal/GLTotal/Gap — authoritative,
   must match the aggregate check exactly), (2) a fixed list of blind spots
   this check cannot detect, (3) orphan rows under the control account's
   subtree framed explicitly as unproven candidates, not a fix. See that
   section's own comment for the full reasoning and the live numbers that
   proved the old single-list version misleading.

   ----------------------------------------------------------------------------
   CAPS
   ----------------------------------------------------------------------------
   Every branch caps output (TOP 200 tickets for check 1's underlying ticket
   set before exploding to lines; TOP 500 rows for every other check's row-
   level result set), ordered so the most material rows surface first
   (largest dollar variance / balance, most recent activity, or largest
   occurrence count, per check). Checks 12/13's result set 2 (blind spots)
   is a small fixed list, not row-level data, so no cap applies to it.
============================================================================ */

IF OBJECT_ID('dbo.sp_rpt_DataHealthCheckDetail', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_DataHealthCheckDetail;
GO

CREATE PROCEDURE dbo.sp_rpt_DataHealthCheckDetail
    @Seq       int,
    @DateFrom  date,
    @DateTo    date,
    @AsOfDate  date = NULL          -- AR/AP checks; defaults to @DateTo, same as sp_rpt_DataHealthCheck
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
        /* ORDER BY ABS(...), not the raw signed sum: a handful of rows have a
           negative (Debit+Credit) sum and were sorting to the bottom under
           the old `ORDER BY (td.Debit + td.Credit) DESC`, which meant the
           visible TOP 500 could sum to MORE than the true full-population
           total (accounting-reviewer finding, 2026-09-12; one-line fix, not
           worth leaving as a cosmetic-quirk comment). */
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

    /* ==== 12/13. Tie-out gaps — REDESIGNED 2026-09-12 (accounting-reviewer finding) ====
       ------------------------------------------------------------------------
       WHY THE ORIGINAL VERSION WAS WRONG (do not reintroduce this pattern)
       ------------------------------------------------------------------------
       The aggregate check's GL side (@ARGL / @APGL) is computed with an
       INNER JOIN TicketMaster. By construction, an orphan TicketDetails row
       (no matching TicketMaster header) contributes ZERO to that GL total —
       it is mathematically impossible for an orphan row to be part of what
       currently causes the reported gap, because the gap is a function of
       exactly the rows that DID make it into the INNER JOIN. The old version
       of this branch showed "orphan rows under this control account" as if
       that list were the fix for the gap. Live-verified 2026-09-12:
         Check 12 (AR): gap = 8,179.20. Orphan rows: one at exactly 8,179.20
           (a real candidate) and one at 165,433,465.56 (unrelated — would
           blow the gap out to ~165.4M if headered, not close it).
         Check 13 (AP): gap = 670,253,758.77. Orphan rows sum to
           748,326,173.53 — overshoots the true gap by 78,072,414.76. None of
           the 3 rows, alone or combined, reconciles to the reported figure.
       An orphan row only explains the gap if giving it a header would change
       @ARGL/@APGL by EXACTLY the amount needed to close it — not guaranteed,
       and demonstrably false for most rows above.

       ------------------------------------------------------------------------
       WHAT THIS BRANCH RETURNS NOW — THREE result sets, in this order
       ------------------------------------------------------------------------
       1) Reconciliation summary (one row) — SubledgerTotal, GLTotal, Gap
          (signed), AbsGap, GapDirection. Computed with the IDENTICAL
          subquery text as dbo.sp_rpt_DataHealthCheck's @ARGL/@APGL (copied,
          not refactored into a shared object, so a future edit to one does
          not silently desync from the other without both being touched) —
          this is the one thing that MUST match the aggregate exactly, every
          time. This is the authoritative output; treat it as ground truth.
       2) Known blind spots (fixed rows, same every call) — failure modes
          this check structurally CANNOT detect: (a) a posted/headered
          ticket booked to the wrong account, (b) a Status-value typo,
          (c) a subledger-side data error with no TicketDetails counterpart
          at all, (d) the @AsOfDate-vs-live-snapshot timing mismatch (see
          sql/05-accounting-aging.sql header). None of these produce an
          orphan row, so result set 3 below will never surface them — this
          check is not, and cannot be, a complete explanation of the gap.
       3) Candidate contributors — orphan rows under the control account's
          subtree (same population as check 3, scoped by AncestorCode),
          each annotated with:
            - RowSignedAmount: the Nature-signed amount (Debit-Credit or
              Credit-Debit per coa.Nature) this row WOULD contribute to
              GLTotal if it were headered/posted — NULL when the account
              is not AccountType='D', because such a row would not enter
              the GL comparison even if headered (Hard Rule #3: postability
              is AccountType='D', never LevelNumber).
            - DirectionVsGap: whether that hypothetical contribution moves
              the CURRENT signed gap toward or away from zero, taken in
              ISOLATION. Same-sign ("TOWARD ZERO") does NOT mean this row
              is a proven cause, and does NOT compound linearly if multiple
              rows are recognized together (see the AP overshoot example
              above — three same-direction rows still failed to land on the
              real gap). This is a same-direction candidate flag, not a fix.
            - PctOfGap: RowSignedAmount as a percentage of the current gap.
              A row near 100% (same sign) is worth investigating first; a
              row wildly over or under 100% is very unlikely to be the
              actual explanation even though its direction matches.
          Framed explicitly as CANDIDATE ONLY in the Note column — never
          "the fix". Ordered by |RowSignedAmount| (or |Debit+Credit| for
          non-'D' rows) DESC, capped at TOP 500, same cap discipline as
          every other branch in this proc. */
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

        /* ---- Result set 1: the reconciliation itself (authoritative) ---- */
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

        /* ---- Result set 2: known blind spots (fixed text, same every call) ---- */
        SELECT BlindSpot = CAST(x.v AS varchar(400)) FROM (VALUES
            ('A posted/headered ticket booked to the WRONG account (miscoded to a different account, including a different control account) is invisible here: it has a TicketMaster row, so it nets straight into GLTotal above with no discrepancy flagged, and will never appear in the candidate list below.'),
            ('A Status value typo or unexpected value (anything not exactly POSTED or UPDATED) silently drops that ticket''s lines from GLTotal with no error. The ticket still has a TicketMaster row, so it is not an orphan and will not appear below.'),
            ('A subledger-side data error — a TransactionChargeSales row with no TicketDetails counterpart at all (e.g. a manual balance adjustment made directly on the subledger table) changes SubledgerTotal above with zero footprint in TicketDetails. There is no detail row to surface as a candidate.'),
            ('AsOfDate vs. live snapshot: TransactionChargeSales.Balance is a CURRENT point-in-time balance (no history table). SubledgerTotal above always reflects TODAY''s balance regardless of @AsOfDate, while GLTotal is correctly bounded by @AsOfDate. A stale @AsOfDate can produce or mask a gap unrelated to any row below.')
        ) AS x(v);

        /* ---- Result set 3: candidate contributors — NOT a proof, see Note ---- */
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
        DECLARE @APSubledger13 decimal(18,2) = (SELECT ISNULL(SUM(Balance), 0)
                                                 FROM dbo.APAccounts WHERE Balance > 0);
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

        /* ---- Result set 1: the reconciliation itself (authoritative) ---- */
        SELECT
            Seq            = CAST(13 AS int),
            CheckName      = CAST('AP subledger vs GL 20101/20102/20103 tie-out gap' AS varchar(80)),
            AsOfDate       = CAST(@AsOfDate AS date),
            SubledgerTotal = CAST(@APSubledger13 AS decimal(18,2)),
            GLTotal        = CAST(@APGL13 AS decimal(18,2)),
            Gap            = CAST(@APGap13 AS decimal(18,2)),
            AbsGap         = CAST(ABS(@APGap13) AS decimal(18,2)),
            GapDirection   = CAST(CASE WHEN @APGap13 > 0 THEN 'SUBLEDGER EXCEEDS GL'
                                        WHEN @APGap13 < 0 THEN 'GL EXCEEDS SUBLEDGER'
                                        ELSE 'TIED OUT' END AS varchar(30));

        /* ---- Result set 2: known blind spots (fixed text, same every call) ---- */
        SELECT BlindSpot = CAST(x.v AS varchar(400)) FROM (VALUES
            ('A posted/headered ticket booked to the WRONG account (miscoded to a different account, including a different control account) is invisible here: it has a TicketMaster row, so it nets straight into GLTotal above with no discrepancy flagged, and will never appear in the candidate list below.'),
            ('A Status value typo or unexpected value (anything not exactly POSTED or UPDATED) silently drops that ticket''s lines from GLTotal with no error. The ticket still has a TicketMaster row, so it is not an orphan and will not appear below.'),
            ('A subledger-side data error — an APAccounts row with no TicketDetails counterpart at all (e.g. a manual balance adjustment made directly on the subledger table) changes SubledgerTotal above with zero footprint in TicketDetails. There is no detail row to surface as a candidate.'),
            ('AsOfDate vs. live snapshot: APAccounts.Balance is a CURRENT point-in-time balance (no history table). SubledgerTotal above always reflects TODAY''s balance regardless of @AsOfDate, while GLTotal is correctly bounded by @AsOfDate. A stale @AsOfDate can produce or mask a gap unrelated to any row below.')
        ) AS x(v);

        /* ---- Result set 3: candidate contributors — NOT a proof, see Note ---- */
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

    /* ==== Unknown @Seq — fail loudly rather than silently return nothing ==== */
    RAISERROR('sp_rpt_DataHealthCheckDetail: unknown @Seq value %d (expected 1-15).', 16, 1, @Seq);
END
GO


/* ============================================================================
   SMOKE TEST — every @Seq from 1 to 15, same window used for the health
   check itself. Confirms no @Seq value errors out and reports which checks
   currently have findings.
============================================================================ */
/*
DECLARE @From date = '2026-07-01', @To date = '2026-09-12';

EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 1,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 2,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 3,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 4,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 5,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 6,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 7,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 8,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 9,  @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 10, @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 11, @DateFrom = @From, @DateTo = @To;
-- Seq 12/13 now return THREE result sets each:
--   1) reconciliation (Seq, CheckName, AsOfDate, SubledgerTotal, GLTotal, Gap, AbsGap, GapDirection)
--   2) blind spots (BlindSpot varchar, 4 fixed rows)
--   3) candidate contributors (orphan rows + RowSignedAmount/DirectionVsGap/PctOfGap/Note)
-- Result set 1's AbsGap MUST equal the aggregate's ValueAtRisk for Seq 12/13 exactly.
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 12, @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 13, @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 14, @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 15, @DateFrom = @From, @DateTo = @To;

-- Regression: aggregate Findings should be > 0 exactly for the seqs that
-- come back with rows above (compare against this):
EXEC dbo.sp_rpt_DataHealthCheck @DateFrom = @From, @DateTo = @To;

-- Fails loudly, does not silently return empty:
-- EXEC dbo.sp_rpt_DataHealthCheckDetail @Seq = 99, @DateFrom = @From, @DateTo = @To;
*/
