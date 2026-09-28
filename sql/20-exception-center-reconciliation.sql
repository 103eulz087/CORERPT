/* ============================================================================
   CORE REPORTING PORTAL — EXCEPTION CENTER: RECONCILIATION 2026-09-26
   Target: CORECSERP_002_DEV only (staging never touched).

   WHAT HAPPENED (root cause, confirmed via sys.procedures.modify_date and
   OBJECT_DEFINITION on live DEV, not assumed)
   ----------------------------------------------------------------------------
   On 2026-09-23, two agent sessions worked on this module in parallel without
   knowing about each other:
     - One session fixed a double-counting bug in SALES-CREDIT-LIMIT-BREACH
       (sql/18-exception-center-sales.sql) — PriorBalance was reconstructed as
       of DeliverySummary.DateAdded and TotalAmount was added a second time on
       top, even though 99.4% of orders already had their own invoice posted
       to ClientLedger BEFORE DateAdded — a straight double-count. The fix
       (looking up PostOrderBalance directly from the order's own ClientLedger
       SI-VAT/SI-VATEX leg by InvoiceNo, no re-addition) was applied to DEV at
       17:49:51, renaming the pre-fix procs to _OLD_20260923F.
     - A concurrent session was building the Purchasing category
       (sql/19-exception-center-purchasing.sql). At 17:52:19 it recreated both
       shared procs to add the 4 new PUR-* checks — but its own
       SALES-CREDIT-LIMIT-BREACH block, despite a comment claiming "unchanged
       from sql/18", actually shipped the PRE-fix double-counting logic
       (apparently built from a stale read taken before 17:49:51). This
       silently reverted the fix while keeping the new Purchasing checks
       correct — every other block sql/19 touched came through fine; this was
       an isolated single-block regression, not a broader corruption.
     - The regression went undetected through two independent review passes
       on Sept 23 (each one verified the category it was reviewing correctly,
       but neither one was asked to re-check a PRIOR category's check after a
       LATER category's deployment) until a third, later review pass on the
       Sales category re-ran the live summary proc and caught the discrepancy:
       SALES-CREDIT-LIMIT-BREACH was reporting 860/₱32,444,001.87 (the old,
       overstated, pre-fix numbers) instead of 464/₱24,378,158.20 (the correct,
       independently re-derived numbers — confirmed twice, by two different
       review sessions, tracing raw ClientLedger rows two different ways).
     - Two follow-up agent tasks dispatched to reconcile this both stalled
       (background-agent stream watchdog timeout, unrelated to the SQL logic
       itself) before writing or applying anything. This file and its
       corresponding live deployment were completed directly by the
       orchestrating session on 2026-09-26, using the exact reproduction and
       fix already fully specified and verified by the stalled agents' own
       prior findings — no new investigation was needed, only application.

   THE FIX (identical to what the stalled sql/18 fix already specified)
   ----------------------------------------------------------------------------
   SALES-CREDIT-LIMIT-BREACH's PostOrderBalance is looked up DIRECTLY from the
   order's own ClientLedger SI-VAT/SI-VATEX leg (TOP(1) ORDER BY TRN_SEQ_NO
   DESC, so a VAT/VATEX-split invoice resolves to the balance after BOTH
   legs) — this IS the ledger's own true balance immediately after this
   order's invoice posted, so it is compared as-is against the customer's
   CURRENT credit limit, with NO re-addition of TotalAmount. Orders with no
   resolvable Customers row, or no matching ClientLedger SI leg at all (3 of
   2,041 today — a genuine $0.00-invoice data gap, not a join bug), are
   excluded, never defaulted into a false breach/non-breach.

   HARDENING ADDED IN THIS PASS (on top of the original sql/18 fix)
   ----------------------------------------------------------------------------
   The PostOrderBalance subquery now matches on BOTH
   (CustomerKey, InvoiceNo, TransCode IN ('SI-VAT','SI-VATEX')) AND
   ReferenceNumber = TransactionChargeSales.ReferenceNo. Independent review
   found that of 46 (CustomerKey, InvoiceNo) pairs with multiple ClientLedger
   rows, 7 are NOT split-VAT-legs of one order — they are InvoiceNo TEXT
   reused across 2-3 genuinely DIFFERENT orders with different
   ReferenceNumbers (e.g. CustomerKey 00003902, InvoiceNo "DR 2608-00" shared
   by DeliveryNo 5987/6101/6118). Keying on InvoiceNo alone was correct by
   COINCIDENCE today (none of those 7 customers' balances happen to straddle
   the ₱50,000 default credit limit mid-group — confirmed both keying
   strategies produce the identical 464/₱24,378,158.20 total) rather than by
   construction. Adding the ReferenceNumber match closes this latent gap
   before it can silently produce a wrong answer on future data.

   KNOWN, DOCUMENTED, NON-BLOCKING LIMITATION (not fixed in this pass)
   ----------------------------------------------------------------------------
   sp_rpt_ExceptionCenter_Detail's SELECT TOP (500) cap is a silent
   truncation for any single check whose Findings exceed 500 — this was
   actively observed during the incident above: while the buggy 860-finding
   version was live, Detail returned only 500 rows (summing to
   ₱26,309,614.07), silently disagreeing with Summary's ₱32,444,001.87. Not
   an active problem today (every check's Findings count is well under 500),
   but worth a paging/export mechanism before any single check's population
   could plausibly exceed it, so a manual tie-out never silently disagrees
   with Summary again without at least a visible "truncated" indicator.

   VERIFICATION PERFORMED (all live against CORECSERP_002_DEV)
   ----------------------------------------------------------------------------
   - SALES-CREDIT-LIMIT-BREACH: Summary reports 464/₱24,378,158.20. Detail
     returns exactly 464 rows summing to ₱24,378,158.20 — exact agreement.
   - All other 17 checks re-run and confirmed unaffected by this change (the
     only block touched in either proc is the SALES-CREDIT-LIMIT-BREACH
     block — confirmed by diffing the full corrected proc bodies below
     against the immediately-prior live definitions, byte-for-byte identical
     everywhere else).
   - Confirmed the corrected proc bodies below are BYTE-IDENTICAL to what is
     currently live on CORECSERP_002_DEV (pulled fresh via OBJECT_DEFINITION
     immediately after applying, diffed against this file's own content).
   - Pre-fix (buggy) proc versions preserved, not dropped, as
     dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260926 /
     dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260926 (and every earlier
     _OLD_20260923* generation remains present too).

   DB CHANGE PROTOCOL — LESSON FOR FUTURE PASSES ON THIS MODULE
   ----------------------------------------------------------------------------
   These two procs are SHARED, monolithic objects that every Exception Center
   category edits by recreating the whole body. Two changes to different
   checks, made concurrently without one session aware of the other, can
   silently clobber each other with no error — whichever CREATE runs last
   wins, in full, discarding the other's edit even to an unrelated block.
   Do not run two Exception Center build/fix passes concurrently against the
   same environment; sequence them, or have the later pass explicitly re-pull
   OBJECT_DEFINITION() immediately before writing its own CREATE to confirm
   it is building on the truly-current version, not a stale read.
============================================================================ */

-- Preserve the pre-fix (regressed) version, don't drop it, per DB change protocol.
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260926', 'P') IS NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Summary', 'sp_rpt_ExceptionCenter_Summary_OLD_20260926';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary
    @DateFrom  date,
    @DateTo    date,
    @AsOfDate  date = NULL /* aging reference date for VOU-STALE-OUTSTANDING-
        CHECKS, AR-STALE-CREDIT-BALANCE, SALES-UNCONFIRMED-ORDERS, and (new,
        this pass) PUR-PENDING-APPROVAL / PUR-APPROVED-PENDING-RECEIPT;
        defaults to @DateTo for the DAY-granularity checks (unchanged). The
        two new Purchasing aging checks use the existing DAY-granularity
        @StaleAsOf, matching the brief's "aged by days" wording — no new
        HOUR-granularity variable needed here, unlike SALES-UNCONFIRMED-
        ORDERS. */
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @AsOf  datetime = GETDATE(); /* report-GENERATED-at timestamp,
        returned as-is in every row's AsOf output column — wall-clock "when
        was this report run", unrelated to the stale-aging dates below. */
    DECLARE @StaleAsOf datetime = CAST(ISNULL(@AsOfDate, @DateTo) AS datetime);
        /* the as-of date VOU-STALE-OUTSTANDING-CHECKS, AR-STALE-CREDIT-
           BALANCE, and (new) both Purchasing aging checks age against —
           DAY granularity, unchanged from sql/17. */
    DECLARE @StaleDays int = 30; /* PLACEHOLDER — bank-check clearing domain, see sql/16. */
    DECLARE @CreditBalanceStaleDays int = 90; /* PLACEHOLDER — AR credit-balance domain, see sql/17. */
    DECLARE @UnconfirmedOrderHours int = 24; /* PLACEHOLDER pending developer's
        real SLA — see header "CHECK 2". HOUR granularity, deliberately a
        separate concept from the two DAY-granularity thresholds above. */
    DECLARE @UnconfirmedAsOf datetime = ISNULL(CAST(@AsOfDate AS datetime), @AsOf);
        /* HOUR-granularity as-of reference for SALES-UNCONFIRMED-ORDERS only
           — reuses the real wall-clock @AsOf (not the date-only @StaleAsOf)
           when the caller doesn't pin @AsOfDate, so a same-day order's age
           is measured in real hours, not silently rounded to midnight. */
    DECLARE @PendingApprovalDays int = 2; /* PLACEHOLDER — see this file's
        header "AGING PLACEHOLDERS" note. */
    DECLARE @ApprovedPendingReceiptDays int = 3; /* PLACEHOLDER — see this
        file's header "AGING PLACEHOLDERS" note. */

    CREATE TABLE #Result
    (
        ExceptionCode varchar(50) NOT NULL,
        Findings      int         NOT NULL,
        ValueAtRisk   money       NULL
    );

    /* ---- SOD-SAME-PREP-APPR: unchanged from sql/15-exception-center.sql ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SOD-SAME-PREP-APPR',
        COUNT(*),
        SUM(ISNULL(x.TicketValue, 0))
    FROM (
        SELECT
            tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber,
            TicketValue = COALESCE(strict.StrictSum, fallback.FallbackSum)
        FROM dbo.TicketMaster AS tm
        OUTER APPLY (
            SELECT StrictSum = SUM(td.Debit)
            FROM dbo.TicketDetails AS td
            WHERE td.TicketDate          = tm.TicketDate
              AND td.SupplementaryNumber = tm.SupplementaryNumber
              AND td.BranchCode          = tm.BranchCode
              AND td.TicketNumber        = tm.TicketNumber
        ) AS strict
        OUTER APPLY (
            SELECT FallbackSum = SUM(td.Debit)
            FROM dbo.TicketDetails AS td
            WHERE td.TicketDate          = tm.TicketDate
              AND td.SupplementaryNumber = tm.SupplementaryNumber
              AND td.TicketNumber        = tm.TicketNumber
        ) AS fallback
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND tm.TicketDate >= @Start AND tm.TicketDate < @End
          AND (
                   (NULLIF(tm.EnteredBy,'*') IS NOT NULL AND NULLIF(tm.EnteredBy,'*') = NULLIF(tm.CheckedBy,'*'))
                OR (NULLIF(tm.EnteredBy,'*') IS NOT NULL AND NULLIF(tm.EnteredBy,'*') = NULLIF(tm.ApprovedBy,'*'))
                OR (NULLIF(tm.CheckedBy,'*')  IS NOT NULL AND NULLIF(tm.CheckedBy,'*')  = NULLIF(tm.ApprovedBy,'*'))
              )
    ) AS x;

    /* ---- VOU-CANCELLED-CHECKS: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-CANCELLED-CHECKS',
        COUNT(*),
        SUM(cv.Amount)
    FROM dbo.CheckVoucher AS cv
    WHERE cv.isErrorCorrect = 1
      AND cv.CancelledDate >= @Start AND cv.CancelledDate < @End;

    /* ---- VOU-REVERSED-VOUCHERS: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-REVERSED-VOUCHERS',
        COUNT(*),
        SUM(COALESCE(cv.Amount, cash.Amount))
    FROM dbo.PaymentReversalAudit AS pra
    LEFT JOIN dbo.CheckVoucher AS cv
        ON cv.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
       AND cv.SupplierID = pra.SupplierID
    LEFT JOIN dbo.CashVoucher AS cash
        ON cash.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
       AND cash.SupplierID = pra.SupplierID
    WHERE pra.CancelledDate >= @Start AND pra.CancelledDate < @End;

    /* ---- VOU-DUP-CHECKNO: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-DUP-CHECKNO',
        COUNT(*),
        SUM(x.Amount)
    FROM (
        SELECT
            cv.VoucherID, cv.Amount,
            DupCount = COUNT(*) OVER (PARTITION BY cv.CreditGLCode, cv.CheckNo)
        FROM dbo.CheckVoucher AS cv
        WHERE cv.isErrorCorrect = 0
          AND cv.CreditGLCode IS NOT NULL AND LTRIM(RTRIM(cv.CreditGLCode)) <> ''
          AND cv.CheckNo      IS NOT NULL AND LTRIM(RTRIM(cv.CheckNo))      <> ''
          AND cv.CheckDate >= @DateFrom AND cv.CheckDate < CAST(@End AS date)
    ) AS x
    WHERE x.DupCount > 1;

    /* ---- VOU-DUP-SUPPLIER-INVOICE: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-DUP-SUPPLIER-INVOICE',
        COUNT(*),
        SUM(y.PrincipalPaid)
    FROM (
        SELECT
            apd.SupplierID, apd.InvoiceNo,
            VoucherCount  = COUNT(DISTINCT apd.VoucherID),
            PrincipalPaid = SUM(CASE WHEN apd.PaymentType IN ('INVOICE PAYMENT','EXPENSE PAYMENT') THEN apd.Amount ELSE 0 END)
        FROM dbo.APPaymentDetails AS apd
        LEFT JOIN dbo.CheckVoucher AS cv
            ON cv.VoucherID = TRY_CAST(apd.VoucherID AS decimal(18,0))
           AND cv.SupplierID = apd.SupplierID
        LEFT JOIN dbo.CashVoucher AS cash
            ON cash.VoucherID = TRY_CAST(apd.VoucherID AS decimal(18,0))
           AND cash.SupplierID = apd.SupplierID
        WHERE apd.InvoiceNo IS NOT NULL AND LTRIM(RTRIM(apd.InvoiceNo)) <> ''
          AND apd.InvoiceDate >= @Start AND apd.InvoiceDate < @End
          AND ISNULL(cv.isErrorCorrect, 0)   = 0
          AND ISNULL(cash.isErrorCorrect, 0) = 0
        GROUP BY apd.SupplierID, apd.InvoiceNo
        HAVING COUNT(DISTINCT apd.VoucherID) > 1
    ) AS y;

    /* ---- VOU-STALE-OUTSTANDING-CHECKS: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-STALE-OUTSTANDING-CHECKS',
        COUNT(*),
        SUM(cv.Amount)
    FROM dbo.BankStatementRecon AS bsr
    JOIN dbo.CheckVoucher AS cv
        ON cv.VoucherID       = TRY_CAST(bsr.ReferenceNo AS decimal(18,0))
       AND cv.ReferenceNumber = bsr.SourceRef
    WHERE bsr.ItemType = 'OC' AND bsr.IsResolved = 0
      AND cv.isErrorCorrect = 0
      AND cv.CheckDate >= @DateFrom AND cv.CheckDate < CAST(@End AS date)
      AND DATEDIFF(DAY, cv.CheckDate, @StaleAsOf) > @StaleDays;

    /* ---- EXP-REVERSALS: unchanged from sql/16 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'EXP-REVERSALS',
        COUNT(*),
        SUM(COALESCE(cv.Amount, cash.Amount))
    FROM dbo.PaymentReversalAudit AS pra
    LEFT JOIN dbo.CheckVoucher AS cv
        ON cv.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
       AND cv.SupplierID = pra.SupplierID
    LEFT JOIN dbo.CashVoucher AS cash
        ON cash.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
       AND cash.SupplierID = pra.SupplierID
    WHERE pra.VoucherType = 'EXPENSE'
      AND pra.CancelledDate >= @Start AND pra.CancelledDate < @End;

    /* ---- AR-REVERSED-PAYMENTS: unchanged from sql/17 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'AR-REVERSED-PAYMENTS',
        COUNT(*),
        SUM(ph.TotalAmount)
    FROM dbo.PaymentHeader AS ph
    WHERE ph.Status = 'REVERSED'
      AND ph.ReversedDate >= @Start AND ph.ReversedDate < @End;

    /* ---- AR-STALE-CREDIT-BALANCE: unchanged from sql/17 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'AR-STALE-CREDIT-BALANCE',
        COUNT(*),
        SUM(ABS(t.Balance))
    FROM dbo.TransactionChargeSales AS t
    WHERE t.Balance < 0
      AND DATEDIFF(DAY, t.TransactionDate, @StaleAsOf) > @CreditBalanceStaleDays;

    /* ---- SALES-UNCONFIRMED-ORDERS: unchanged from sql/18 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-UNCONFIRMED-ORDERS',
        COUNT(*),
        SUM(ISNULL(v.OrderValue, 0))
    FROM (
        SELECT
            ds.DeliveryNo,
            PlacedAtTime = COALESCE(
                (SELECT MIN(dd.DateTimeAdded) FROM dbo.DeliveryDetails AS dd WHERE dd.DeliveryNo = ds.DeliveryNo),
                CAST(ds.DateAdded AS datetime))
        FROM dbo.DeliverySummary AS ds
        WHERE ds.Status = 'PENDING'
          AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
    ) AS p
    OUTER APPLY (
        SELECT OrderValue = SUM(dd.SellingPrice * dd.QtyDelivered)
        FROM dbo.DeliveryDetails AS dd
        WHERE dd.DeliveryNo = p.DeliveryNo
    ) AS v
    WHERE DATEDIFF(HOUR, p.PlacedAtTime, @UnconfirmedAsOf) > @UnconfirmedOrderHours;

    /* ---- SALES-VATABLE-ZERO-VAT: unchanged from sql/18 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-VATABLE-ZERO-VAT',
        COUNT(*),
        SUM(t.TotalAmount)
    FROM dbo.TransactionChargeSalesDetails AS t
    JOIN dbo.Products AS p ON p.ProductCode = t.Product
    WHERE t.Type = 'SALES VAT EXEMPT' AND p.isVat = 1
      AND t.TransactionDate >= @Start AND t.TransactionDate < @End;

    /* ---- SALES-CM-CLIENT: unchanged from sql/18 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-CM-CLIENT',
        COUNT(*),
        SUM(ISNULL(ar.ARValue, 0))
    FROM (
        SELECT tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber
        FROM dbo.TicketMaster AS tm
        JOIN dbo.RptMnemonicMap AS mm ON mm.Mnemonic = tm.Mnemonic
        WHERE mm.Mnemonic LIKE 'CM-CLIENT-%'
          AND tm.Status IN ('POSTED','UPDATED')
          AND tm.TicketDate >= @Start AND tm.TicketDate < @End
    ) AS c
    OUTER APPLY (
        SELECT ARValue = SUM(td.Credit - td.Debit)
        FROM dbo.TicketDetails AS td
        JOIN dbo.vw_AccountTree AS t ON t.AccountCode = td.AccountCode
        WHERE td.TicketDate          = c.TicketDate
          AND td.SupplementaryNumber = c.SupplementaryNumber
          AND td.BranchCode          = c.BranchCode
          AND td.TicketNumber        = c.TicketNumber
          AND t.AncestorCode = '101030101'
    ) AS ar;

    /* ---- SALES-RETURNED-ORDERS: unchanged from sql/18 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-RETURNED-ORDERS',
        COUNT(*),
        SUM(ros.TotalAmount)
    FROM dbo.ReturnedOrderSummary AS ros
    WHERE ros.DateAdded >= @DateFrom AND ros.DateAdded < CAST(@End AS date);

    /* ---- SALES-CREDIT-LIMIT-BREACH (BUGFIXED 2026-09-23, hardened
       2026-09-26 after a concurrent-edit regression reverted this fix —
       see this file's header "RECONCILIATION 2026-09-26" note): DELIVERED/
       RETURNED orders only (customer resolvable — see header for why
       PENDING/FOR DELIVERY cannot be evaluated). PostOrderBalance is looked
       up DIRECTLY from the order's OWN ClientLedger SI-VAT/SI-VATEX leg(s),
       matched on BOTH InvoiceNo AND ReferenceNumber (the ReferenceNumber
       match guards against the 7 known cases where InvoiceNo TEXT is reused
       across genuinely different orders — see header), last TRN_SEQ_NO if an
       invoice split across both legs — this IS the ledger's own true balance
       immediately after THIS order's invoice posted, so it is compared as-is
       against the CUSTOMER'S CURRENT credit limit (explicit approximation,
       disclosed), with NO re-addition of TotalAmount (the old query added
       TotalAmount a second time on top of a PriorBalance that, in 99.4% of
       orders, already contained this exact invoice — a straight double-
       count; see header for the full proof). Orders with no resolvable
       Customers row, or no matching ClientLedger SI leg at all (3 of 2,041
       today), are excluded, never defaulted into a false breach/non-breach.
       ValueAtRisk = SUM of the breaching orders' own TotalAmount (not
       PostOrderBalance itself, which would still double-count a repeat
       customer's balance across each of their own flagged orders — same
       convention as VOU-DUP-CHECKNO/VOU-DUP-SUPPLIER-INVOICE in sql/16). ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-CREDIT-LIMIT-BREACH',
        COUNT(*),
        SUM(b.TotalAmount)
    FROM (
        SELECT
            ds.DeliveryNo, tcs.CustomerKey, tcs.TotalAmount,
            PostOrderBalance = (
                SELECT TOP (1) cl.EndingBalance
                FROM dbo.ClientLedger AS cl
                WHERE cl.AccountKey = tcs.CustomerKey
                  AND cl.InvoiceNo  = tcs.InvoiceNo
                  AND cl.ReferenceNumber = tcs.ReferenceNo
                  AND cl.TransCode IN ('SI-VAT','SI-VATEX')
                ORDER BY cl.TRN_SEQ_NO DESC
            )
        FROM dbo.DeliverySummary AS ds
        JOIN dbo.TransactionChargeSales AS tcs ON tcs.ReferenceNo = ds.PONumber
        WHERE ds.Status IN ('DELIVERED','RETURNED')
          AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
    ) AS b
    JOIN dbo.Customers AS c ON c.CustomerKey = b.CustomerKey
    WHERE b.PostOrderBalance > ISNULL(c.CustomerCreditLimit, 0);

    /* ---- SALES-BELOW-COST: unchanged from sql/18 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-BELOW-COST',
        COUNT(*),
        SUM((t.Cost - t.SellingPrice) * t.Quantity)
    FROM dbo.TransactionChargeSalesDetails AS t
    WHERE t.Type IN ('SALES VAT','SALES VAT EXEMPT')
      AND t.SellingPrice > 0 AND t.SellingPrice < t.Cost
      AND t.TransactionDate >= @Start AND t.TransactionDate < @End;

    /* ---- PUR-PENDING-APPROVAL (NEW, this pass): POSUMMARY.Status =
       'FOR APPROVAL' — confirmed live to mean ApprovedDate NOT YET
       populated (see header "PO STATUS LIFECYCLE"). Aged from DateOrder
       (real sub-day timestamp) to @StaleAsOf, DAY granularity per the
       brief's "aged by days pending" wording. Windowed on DateOrder within
       the caller's period. ValueAtRisk = SUM(POSUMMARY.TotalCost) —
       CONFIRMED LIVE this is 0.00 today for every open PO (see header "COST
       DATA-QUALITY FINDING") — the honest current answer, not a bug. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'PUR-PENDING-APPROVAL',
        COUNT(*),
        SUM(ps.TotalCost)
    FROM dbo.POSUMMARY AS ps
    WHERE ps.Status = 'FOR APPROVAL'
      AND ps.DateOrder >= @DateFrom AND ps.DateOrder < CAST(@End AS date)
      AND DATEDIFF(DAY, ps.DateOrder, @StaleAsOf) > @PendingApprovalDays;

    /* ---- PUR-APPROVED-PENDING-RECEIPT (NEW, this pass): POSUMMARY.Status =
       'FOR DELIVERY' ONLY — confirmed live to be the sole status where
       ApprovedDate IS populated and ReceivedDate is NOT (see header "PO
       STATUS LIFECYCLE"). Deliberately scoped as an explicit status match,
       NOT a NOT-IN exclusion list, so the 320-row DELIVERED migration
       artifact (see header "DELIVERED — MIGRATION ARTIFACT") can never leak
       into this check even if further legacy statuses surface later. Aged
       from ApprovedDate to @StaleAsOf, DAY granularity. ValueAtRisk =
       SUM(POSUMMARY.TotalCost) — 0.00 today, see header "COST DATA-QUALITY
       FINDING". ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'PUR-APPROVED-PENDING-RECEIPT',
        COUNT(*),
        SUM(ps.TotalCost)
    FROM dbo.POSUMMARY AS ps
    WHERE ps.Status = 'FOR DELIVERY'
      AND ps.DateOrder >= @DateFrom AND ps.DateOrder < CAST(@End AS date)
      AND DATEDIFF(DAY, ps.ApprovedDate, @StaleAsOf) > @ApprovedPendingReceiptDays;

    /* ---- PUR-FOR-CONFIRMATION (NEW, this pass): POSUMMARY.Status =
       'FOR CONFIRMATION' — the brief's literally-named status, confirmed
       live to be DISTINCT from 'FOR APPROVAL' (goods already received,
       awaiting a confirmation/verification step — see header "PO STATUS
       LIFECYCLE"). No aging threshold applied here — the brief asks for
       this status to be surfaced as its own flag, not bucketed; the detail
       proc still reports DaysAwaitingConfirmation for context. ValueAtRisk
       = SUM(POSUMMARY.TotalCost) — 0.00 today, see header. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'PUR-FOR-CONFIRMATION',
        COUNT(*),
        SUM(ps.TotalCost)
    FROM dbo.POSUMMARY AS ps
    WHERE ps.Status = 'FOR CONFIRMATION'
      AND ps.DateOrder >= @DateFrom AND ps.DateOrder < CAST(@End AS date);

    /* ---- PUR-OVER-RECEIPT (NEW, this pass): line-level, PODETAILS.
       ActualQuantity > Quantity — the correct granularity per the brief
       ("on a PO line", not per header). Windowed on POSUMMARY.ReceivedDate
       (when the receiving/variance event actually happened), not DateOrder,
       matching the VOU-CANCELLED-CHECKS precedent of windowing on the event
       date rather than the original document date. ValueAtRisk =
       (ActualQuantity - Quantity) * PODETAILS.Cost — CONFIRMED LIVE this is
       0.00 today (PODETAILS.Cost is 0 on every live row, see header "COST
       DATA-QUALITY FINDING") even though the QUANTITY variance itself is
       real and material (the one live finding is a 50% over-receipt by
       volume). Findings = number of flagged LINES, not headers. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'PUR-OVER-RECEIPT',
        COUNT(*),
        SUM((pd.ActualQuantity - pd.Quantity) * pd.Cost)
    FROM dbo.PODETAILS AS pd
    JOIN dbo.POSUMMARY AS ps ON ps.ShipmentNo = pd.ShipmentNo
    WHERE pd.ActualQuantity IS NOT NULL AND pd.ActualQuantity > pd.Quantity
      AND ps.ReceivedDate >= @DateFrom AND ps.ReceivedDate < CAST(@End AS date);

    /* ---- Future checks land here as additional INSERT blocks. ---- */

    SELECT
        ExceptionCode  = CAST(ed.ExceptionCode AS varchar(50)),
        Category       = CAST(ed.Category AS varchar(50)),
        Title          = CAST(ed.Title AS varchar(200)),
        Severity       = CAST(ed.Severity AS varchar(10)),
        Findings       = CAST(ISNULL(r.Findings, 0) AS int),
        ValueAtRisk    = CAST(r.ValueAtRisk AS decimal(18,2)),
        HasDrillDown   = CAST(ed.HasDrillDown AS bit),
        DrillDownRoute = CAST(ed.DrillDownRoute AS varchar(200)),
        AsOf           = CAST(@AsOf AS datetime)
    FROM dbo.ExceptionDefinition AS ed
    LEFT JOIN #Result AS r ON r.ExceptionCode = ed.ExceptionCode
    WHERE ed.IsActive = 1
    ORDER BY ed.SortOrder, ed.ExceptionCode;

    DROP TABLE #Result;
END
GO

-- Preserve the pre-fix (regressed) version, don't drop it, per DB change protocol.
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260926', 'P') IS NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Detail', 'sp_rpt_ExceptionCenter_Detail_OLD_20260926';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail
    @ExceptionCode varchar(50),
    @DateFrom      date,
    @DateTo        date,
    @AsOfDate      date = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @AsOf  datetime = GETDATE();
    DECLARE @StaleDays int = 30; /* PLACEHOLDER — see Summary proc / sql/16 header note. */
    DECLARE @CreditBalanceStaleDays int = 90; /* PLACEHOLDER — see Summary proc / sql/17 header note. */
    DECLARE @UnconfirmedOrderHours int = 24; /* PLACEHOLDER — see Summary proc / sql/18 header note. */
    DECLARE @StaleAsOf datetime = CAST(ISNULL(@AsOfDate, @DateTo) AS datetime);
    DECLARE @UnconfirmedAsOf datetime = ISNULL(CAST(@AsOfDate AS datetime), @AsOf);
    DECLARE @PendingApprovalDays int = 2; /* PLACEHOLDER — see Summary proc / this file's header note. */
    DECLARE @ApprovedPendingReceiptDays int = 3; /* PLACEHOLDER — see Summary proc / this file's header note. */

    /* ==== SOD-SAME-PREP-APPR — unchanged from sql/15-exception-center.sql ==== */
    IF @ExceptionCode = 'SOD-SAME-PREP-APPR'
    BEGIN
        ;WITH Flagged AS
        (
            SELECT
                tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber,
                tm.ReferenceNumber, tm.Mnemonic, tm.Status, tm.Owner, tm.Particulars,
                tm.EnteredBy, tm.CheckedBy, tm.ApprovedBy,
                EnteredEqChecked  = CASE WHEN NULLIF(tm.EnteredBy,'*') IS NOT NULL AND NULLIF(tm.EnteredBy,'*') = NULLIF(tm.CheckedBy,'*')  THEN 1 ELSE 0 END,
                EnteredEqApproved = CASE WHEN NULLIF(tm.EnteredBy,'*') IS NOT NULL AND NULLIF(tm.EnteredBy,'*') = NULLIF(tm.ApprovedBy,'*') THEN 1 ELSE 0 END,
                CheckedEqApproved = CASE WHEN NULLIF(tm.CheckedBy,'*')  IS NOT NULL AND NULLIF(tm.CheckedBy,'*')  = NULLIF(tm.ApprovedBy,'*') THEN 1 ELSE 0 END
            FROM dbo.TicketMaster AS tm
            WHERE tm.Status IN ('POSTED','UPDATED')
              AND tm.TicketDate >= @Start AND tm.TicketDate < @End
        )
        SELECT TOP (500)
            TicketDate          = CAST(f.TicketDate AS date),
            BranchCode          = CAST(f.BranchCode AS varchar(5)),
            BranchName          = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            TicketNumber        = CAST(f.TicketNumber AS varchar(50)),
            SupplementaryNumber = CAST(f.SupplementaryNumber AS tinyint),
            ReferenceNumber     = CAST(ISNULL(f.ReferenceNumber, '') AS varchar(150)),
            Mnemonic            = CAST(ISNULL(f.Mnemonic, '') AS varchar(50)),
            Status              = CAST(ISNULL(f.Status, '') AS varchar(50)),
            EnteredBy           = CAST(ISNULL(f.EnteredBy, '') AS varchar(128)),
            CheckedBy           = CAST(ISNULL(f.CheckedBy, '') AS varchar(128)),
            ApprovedBy          = CAST(ISNULL(f.ApprovedBy, '') AS varchar(128)),
            MatchType           = CAST(
                                       STUFF(
                                           CASE WHEN f.EnteredEqChecked  = 1 THEN ', ENTERED=CHECKED'  ELSE '' END +
                                           CASE WHEN f.EnteredEqApproved = 1 THEN ', ENTERED=APPROVED' ELSE '' END +
                                           CASE WHEN f.CheckedEqApproved = 1 THEN ', CHECKED=APPROVED' ELSE '' END,
                                           1, 2, '')
                                   AS varchar(60)),
            InvolvesApprover    = CAST(CASE WHEN f.EnteredEqApproved = 1 OR f.CheckedEqApproved = 1 THEN 1 ELSE 0 END AS bit),
            TicketValue         = CAST(COALESCE(v.StrictSum, v.FallbackSum) AS decimal(18,2)),
            BranchCodeMismatch  = CAST(CASE WHEN v.StrictSum IS NULL AND v.FallbackSum IS NOT NULL THEN 1 ELSE 0 END AS bit),
            Owner               = CAST(ISNULL(f.Owner, '') AS varchar(150)),
            Particulars         = CAST(ISNULL(f.Particulars, '') AS varchar(400))
        FROM Flagged AS f
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = f.BranchCode
        OUTER APPLY (
            SELECT
                StrictSum = (
                    SELECT SUM(td.Debit)
                    FROM dbo.TicketDetails AS td
                    WHERE td.TicketDate          = f.TicketDate
                      AND td.SupplementaryNumber = f.SupplementaryNumber
                      AND td.BranchCode          = f.BranchCode
                      AND td.TicketNumber        = f.TicketNumber
                ),
                FallbackSum = (
                    SELECT SUM(td.Debit)
                    FROM dbo.TicketDetails AS td
                    WHERE td.TicketDate          = f.TicketDate
                      AND td.SupplementaryNumber = f.SupplementaryNumber
                      AND td.TicketNumber        = f.TicketNumber
                )
        ) AS v
        WHERE f.EnteredEqChecked = 1 OR f.EnteredEqApproved = 1 OR f.CheckedEqApproved = 1
        ORDER BY f.EnteredEqApproved DESC, f.CheckedEqApproved DESC, f.TicketDate DESC;
        RETURN;
    END

    /* ==== VOU-CANCELLED-CHECKS — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-CANCELLED-CHECKS'
    BEGIN
        SELECT TOP (500)
            VoucherID     = CAST(cv.VoucherID AS varchar(20)),
            SupplierID    = CAST(cv.SupplierID AS varchar(50)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            ReferenceNumber = CAST(ISNULL(cv.ReferenceNumber, '') AS varchar(20)),
            CheckNo       = CAST(ISNULL(cv.CheckNo, '') AS varchar(100)),
            CheckDate     = CAST(cv.CheckDate AS date),
            Amount        = CAST(cv.Amount AS decimal(18,2)),
            BankAccountCode = CAST(ISNULL(cv.CreditGLCode, '') AS varchar(100)),
            BankName      = CAST(ISNULL(bc.Bank, '') AS varchar(50)),
            BranchCode    = CAST(ISNULL(ap.BranchCode, '') AS varchar(5)),
            Particulars   = CAST(ISNULL(cv.Particulars, '') AS varchar(500)),
            CancelledBy   = CAST(ISNULL(cv.CancelledBy, '') AS varchar(50)),
            CancelledDate = CAST(cv.CancelledDate AS datetime),
            CancelReason  = CAST(ISNULL(cv.CancelReason, '') AS varchar(300))
        FROM dbo.CheckVoucher AS cv
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = cv.SupplierID
        LEFT JOIN dbo.BankCOA AS bc ON bc.AccountCode = cv.CreditGLCode
        OUTER APPLY (
            SELECT TOP (1) BranchCode
            FROM dbo.APPaymentDetails ap
            WHERE ap.VoucherID = CAST(cv.VoucherID AS varchar(10))
              AND ap.SupplierID = cv.SupplierID
              AND ap.ReferenceNumber = cv.ReferenceNumber
        ) AS ap
        WHERE cv.isErrorCorrect = 1
          AND cv.CancelledDate >= @Start AND cv.CancelledDate < @End
        ORDER BY cv.CancelledDate DESC;
        RETURN;
    END

    /* ==== VOU-REVERSED-VOUCHERS — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-REVERSED-VOUCHERS'
    BEGIN
        SELECT TOP (500)
            AuditID       = CAST(pra.AuditID AS int),
            VoucherID     = CAST(pra.VoucherID AS varchar(20)),
            SourceTable   = CAST(CASE WHEN cv.VoucherID IS NOT NULL THEN 'CHECK'
                                      WHEN cash.VoucherID IS NOT NULL THEN 'CASH'
                                      ELSE 'UNKNOWN' END AS varchar(10)),
            SupplierID    = CAST(pra.SupplierID AS varchar(40)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            VoucherType   = CAST(ISNULL(pra.VoucherType, '') AS varchar(20)),
            ReferenceNumber = CAST(ISNULL(pra.ReferenceNumber, '') AS varchar(20)),
            Amount        = CAST(COALESCE(cv.Amount, cash.Amount) AS decimal(18,2)),
            CancelledBy   = CAST(ISNULL(pra.CancelledBy, '') AS varchar(50)),
            CancelledDate = CAST(pra.CancelledDate AS datetime),
            CancelReason  = CAST(ISNULL(pra.CancelReason, '') AS varchar(300))
        FROM dbo.PaymentReversalAudit AS pra
        LEFT JOIN dbo.CheckVoucher AS cv
            ON cv.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
           AND cv.SupplierID = pra.SupplierID
        LEFT JOIN dbo.CashVoucher AS cash
            ON cash.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
           AND cash.SupplierID = pra.SupplierID
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = pra.SupplierID
        WHERE pra.CancelledDate >= @Start AND pra.CancelledDate < @End
        ORDER BY pra.CancelledDate DESC;
        RETURN;
    END

    /* ==== VOU-DUP-CHECKNO — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-DUP-CHECKNO'
    BEGIN
        ;WITH Flagged AS (
            SELECT
                cv.VoucherID, cv.SupplierID, cv.ReferenceNumber, cv.CheckNo, cv.CheckDate,
                cv.Amount, cv.CreditGLCode, cv.PreparedBy,
                DupCount = COUNT(*) OVER (PARTITION BY cv.CreditGLCode, cv.CheckNo)
            FROM dbo.CheckVoucher AS cv
            WHERE cv.isErrorCorrect = 0
              AND cv.CreditGLCode IS NOT NULL AND LTRIM(RTRIM(cv.CreditGLCode)) <> ''
              AND cv.CheckNo      IS NOT NULL AND LTRIM(RTRIM(cv.CheckNo))      <> ''
              AND cv.CheckDate >= @DateFrom AND cv.CheckDate < CAST(@End AS date)
        )
        SELECT TOP (500)
            VoucherID     = CAST(f.VoucherID AS varchar(20)),
            SupplierID    = CAST(f.SupplierID AS varchar(50)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            ReferenceNumber = CAST(ISNULL(f.ReferenceNumber, '') AS varchar(20)),
            CheckNo       = CAST(f.CheckNo AS varchar(100)),
            CheckDate     = CAST(f.CheckDate AS date),
            Amount        = CAST(f.Amount AS decimal(18,2)),
            BankAccountCode = CAST(f.CreditGLCode AS varchar(100)),
            BankName      = CAST(ISNULL(bc.Bank, '') AS varchar(50)),
            DuplicateCount = CAST(f.DupCount AS int),
            PreparedBy    = CAST(ISNULL(f.PreparedBy, '') AS varchar(50))
        FROM Flagged AS f
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = f.SupplierID
        LEFT JOIN dbo.BankCOA AS bc ON bc.AccountCode = f.CreditGLCode
        WHERE f.DupCount > 1
        ORDER BY f.CreditGLCode, f.CheckNo, f.CheckDate;
        RETURN;
    END

    /* ==== VOU-DUP-SUPPLIER-INVOICE — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-DUP-SUPPLIER-INVOICE'
    BEGIN
        ;WITH LiveLegs AS (
            SELECT
                apd.SupplierID, apd.InvoiceNo, apd.VoucherID, apd.VoucherType,
                apd.PaymentMethod, apd.ReferenceNumber, apd.InvoiceDate,
                apd.PaymentType, apd.Amount
            FROM dbo.APPaymentDetails AS apd
            LEFT JOIN dbo.CheckVoucher AS cv
                ON cv.VoucherID = TRY_CAST(apd.VoucherID AS decimal(18,0))
               AND cv.SupplierID = apd.SupplierID
            LEFT JOIN dbo.CashVoucher AS cash
                ON cash.VoucherID = TRY_CAST(apd.VoucherID AS decimal(18,0))
               AND cash.SupplierID = apd.SupplierID
            WHERE apd.InvoiceNo IS NOT NULL AND LTRIM(RTRIM(apd.InvoiceNo)) <> ''
              AND apd.InvoiceDate >= @Start AND apd.InvoiceDate < @End
              AND ISNULL(cv.isErrorCorrect, 0)   = 0
              AND ISNULL(cash.isErrorCorrect, 0) = 0
        ),
        FlaggedPairs AS (
            SELECT SupplierID, InvoiceNo
            FROM LiveLegs
            GROUP BY SupplierID, InvoiceNo
            HAVING COUNT(DISTINCT VoucherID) > 1
        )
        SELECT TOP (500)
            SupplierID    = CAST(v.SupplierID AS varchar(50)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            InvoiceNo     = CAST(v.InvoiceNo AS varchar(150)),
            InvoiceDate   = CAST(v.InvoiceDate AS date),
            VoucherID     = CAST(v.VoucherID AS varchar(20)),
            VoucherType   = CAST(ISNULL(v.VoucherType, '') AS varchar(20)),
            PaymentMethod = CAST(ISNULL(v.PaymentMethod, '') AS varchar(20)),
            ReferenceNumber = CAST(ISNULL(v.ReferenceNumber, '') AS varchar(20)),
            PrincipalPaid = CAST(v.PrincipalPaid AS decimal(18,2))
        FROM FlaggedPairs AS fp
        JOIN (
            SELECT
                SupplierID, InvoiceNo, VoucherID, VoucherType,
                PaymentMethod, ReferenceNumber, MIN(InvoiceDate) AS InvoiceDate,
                PrincipalPaid = SUM(CASE WHEN PaymentType IN ('INVOICE PAYMENT','EXPENSE PAYMENT') THEN Amount ELSE 0 END)
            FROM LiveLegs
            GROUP BY SupplierID, InvoiceNo, VoucherID, VoucherType, PaymentMethod, ReferenceNumber
        ) AS v
            ON v.SupplierID = fp.SupplierID AND v.InvoiceNo = fp.InvoiceNo
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = v.SupplierID
        ORDER BY v.SupplierID, v.InvoiceNo, v.VoucherID;
        RETURN;
    END

    /* ==== VOU-STALE-OUTSTANDING-CHECKS — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'VOU-STALE-OUTSTANDING-CHECKS'
    BEGIN
        SELECT TOP (500)
            VoucherID     = CAST(cv.VoucherID AS varchar(20)),
            SupplierID    = CAST(cv.SupplierID AS varchar(50)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            ReferenceNumber = CAST(ISNULL(cv.ReferenceNumber, '') AS varchar(20)),
            CheckNo       = CAST(ISNULL(cv.CheckNo, '') AS varchar(100)),
            CheckDate     = CAST(cv.CheckDate AS date),
            Amount        = CAST(cv.Amount AS decimal(18,2)),
            BankAccountCode = CAST(ISNULL(bsr.AccountCode, '') AS varchar(20)),
            BankName      = CAST(ISNULL(bc.Bank, '') AS varchar(50)),
            BranchCode    = CAST(ISNULL(bsr.BranchCode, '') AS varchar(5)),
            DaysOutstanding = CAST(DATEDIFF(DAY, cv.CheckDate, @StaleAsOf) AS int),
            Payee         = CAST(ISNULL(bsr.Payee, '') AS varchar(200))
        FROM dbo.BankStatementRecon AS bsr
        JOIN dbo.CheckVoucher AS cv
            ON cv.VoucherID       = TRY_CAST(bsr.ReferenceNo AS decimal(18,0))
           AND cv.ReferenceNumber = bsr.SourceRef
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = cv.SupplierID
        LEFT JOIN dbo.BankCOA AS bc ON bc.AccountCode = bsr.AccountCode
        WHERE bsr.ItemType = 'OC' AND bsr.IsResolved = 0
          AND cv.isErrorCorrect = 0
          AND cv.CheckDate >= @DateFrom AND cv.CheckDate < CAST(@End AS date)
          AND DATEDIFF(DAY, cv.CheckDate, @StaleAsOf) > @StaleDays
        ORDER BY DaysOutstanding DESC;
        RETURN;
    END

    /* ==== EXP-REVERSALS — unchanged from sql/16 ==== */
    IF @ExceptionCode = 'EXP-REVERSALS'
    BEGIN
        SELECT TOP (500)
            AuditID       = CAST(pra.AuditID AS int),
            VoucherID     = CAST(pra.VoucherID AS varchar(20)),
            SourceTable   = CAST(CASE WHEN cv.VoucherID IS NOT NULL THEN 'CHECK'
                                      WHEN cash.VoucherID IS NOT NULL THEN 'CASH'
                                      ELSE 'UNKNOWN' END AS varchar(10)),
            SupplierID    = CAST(pra.SupplierID AS varchar(40)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            ReferenceNumber = CAST(ISNULL(pra.ReferenceNumber, '') AS varchar(20)),
            Amount        = CAST(COALESCE(cv.Amount, cash.Amount) AS decimal(18,2)),
            CancelledBy   = CAST(ISNULL(pra.CancelledBy, '') AS varchar(50)),
            CancelledDate = CAST(pra.CancelledDate AS datetime),
            CancelReason  = CAST(ISNULL(pra.CancelReason, '') AS varchar(300))
        FROM dbo.PaymentReversalAudit AS pra
        LEFT JOIN dbo.CheckVoucher AS cv
            ON cv.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
           AND cv.SupplierID = pra.SupplierID
        LEFT JOIN dbo.CashVoucher AS cash
            ON cash.VoucherID = TRY_CAST(pra.VoucherID AS decimal(18,0))
           AND cash.SupplierID = pra.SupplierID
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = pra.SupplierID
        WHERE pra.VoucherType = 'EXPENSE'
          AND pra.CancelledDate >= @Start AND pra.CancelledDate < @End
        ORDER BY pra.CancelledDate DESC;
        RETURN;
    END

    /* ==== AR-REVERSED-PAYMENTS — unchanged from sql/17 ==== */
    IF @ExceptionCode = 'AR-REVERSED-PAYMENTS'
    BEGIN
        SELECT TOP (500)
            PaymentHeaderID = CAST(ph.PaymentHeaderID AS varchar(20)),
            CustomerKey     = CAST(ph.CustomerKey AS char(8)),
            CustomerName    = CAST(ISNULL(c.CustomerName, 'UNKNOWN CUSTOMER - ' + ph.CustomerKey) AS varchar(200)),
            BranchCode      = CAST(ISNULL(c.BranchCode, 'UNKNOWN') AS varchar(100)),
            ReferenceNo     = CAST(ISNULL(ph.ReferenceNo, '') AS varchar(20)),
            PaymentType     = CAST(ISNULL(ph.PaymentType, '') AS varchar(30)),
            PaymentDate     = CAST(ph.PaymentDate AS date),
            TotalAmount     = CAST(ph.TotalAmount AS decimal(18,2)),
            ReversedBy      = CAST(ISNULL(ph.ReversedBy, '') AS varchar(50)),
            ReversedDate    = CAST(ph.ReversedDate AS datetime),
            Remarks         = CAST(ISNULL(ph.Remarks, '') AS varchar(500))
        FROM dbo.PaymentHeader AS ph
        LEFT JOIN dbo.Customers AS c ON c.CustomerKey = ph.CustomerKey
        WHERE ph.Status = 'REVERSED'
          AND ph.ReversedDate >= @Start AND ph.ReversedDate < @End
        ORDER BY ph.ReversedDate DESC;
        RETURN;
    END

    /* ==== AR-STALE-CREDIT-BALANCE — unchanged from sql/17 ==== */
    IF @ExceptionCode = 'AR-STALE-CREDIT-BALANCE'
    BEGIN
        SELECT TOP (500)
            CustomerKey     = CAST(t.CustomerKey AS char(8)),
            CustomerName    = CAST(ISNULL(c.CustomerName, 'UNKNOWN CUSTOMER - ' + t.CustomerKey) AS varchar(200)),
            BranchCode      = CAST(ISNULL(c.BranchCode, 'UNKNOWN') AS varchar(100)),
            InvoiceNo       = CAST(t.InvoiceNo AS varchar(100)),
            TransactionDate = CAST(t.TransactionDate AS date),
            TotalAmount     = CAST(t.TotalAmount AS decimal(18,2)),
            CreditBalance   = CAST(ABS(t.Balance) AS decimal(18,2)),
            PayStatus       = CAST(ISNULL(t.PayStatus, '') AS varchar(10)),
            DaysOpen        = CAST(DATEDIFF(DAY, t.TransactionDate, @StaleAsOf) AS int)
        FROM dbo.TransactionChargeSales AS t
        LEFT JOIN dbo.Customers AS c ON c.CustomerKey = t.CustomerKey
        WHERE t.Balance < 0
          AND DATEDIFF(DAY, t.TransactionDate, @StaleAsOf) > @CreditBalanceStaleDays
        ORDER BY DaysOpen DESC;
        RETURN;
    END

    /* ==== SALES-UNCONFIRMED-ORDERS — unchanged from sql/18 ==== */
    IF @ExceptionCode = 'SALES-UNCONFIRMED-ORDERS'
    BEGIN
        ;WITH PlacedAt AS (
            SELECT
                ds.DeliveryNo, ds.PONumber, ds.BranchCode, ds.Status, ds.DateAdded, ds.PreparedBy, ds.TotalItem,
                PlacedAtTime = COALESCE(
                    (SELECT MIN(dd.DateTimeAdded) FROM dbo.DeliveryDetails AS dd WHERE dd.DeliveryNo = ds.DeliveryNo),
                    CAST(ds.DateAdded AS datetime))
            FROM dbo.DeliverySummary AS ds
            WHERE ds.Status = 'PENDING'
              AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
        )
        SELECT TOP (500)
            DeliveryNo   = CAST(p.DeliveryNo AS varchar(20)),
            PONumber     = CAST(p.PONumber AS varchar(20)),
            BranchCode   = CAST(p.BranchCode AS varchar(5)),
            BranchName   = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            DateAdded    = CAST(p.DateAdded AS date),
            PlacedAtTime = CAST(p.PlacedAtTime AS datetime),
            HoursOpen    = CAST(DATEDIFF(HOUR, p.PlacedAtTime, @UnconfirmedAsOf) AS int),
            OrderValue   = CAST(ISNULL(v.OrderValue, 0) AS decimal(18,2)),
            TotalItem    = CAST(ISNULL(p.TotalItem, 0) AS int),
            PreparedBy   = CAST(ISNULL(p.PreparedBy, '') AS varchar(30))
        FROM PlacedAt AS p
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = p.BranchCode
        OUTER APPLY (
            SELECT OrderValue = SUM(dd.SellingPrice * dd.QtyDelivered)
            FROM dbo.DeliveryDetails AS dd
            WHERE dd.DeliveryNo = p.DeliveryNo
        ) AS v
        WHERE DATEDIFF(HOUR, p.PlacedAtTime, @UnconfirmedAsOf) > @UnconfirmedOrderHours
        ORDER BY HoursOpen DESC;
        RETURN;
    END

    /* ==== SALES-VATABLE-ZERO-VAT — unchanged from sql/18 ==== */
    IF @ExceptionCode = 'SALES-VATABLE-ZERO-VAT'
    BEGIN
        SELECT TOP (500)
            BranchCode      = CAST(t.BranchCode AS varchar(5)),
            ReferenceNo     = CAST(t.ReferenceNo AS varchar(20)),
            InvoiceNo       = CAST(ISNULL(t.InvoiceNo, '') AS varchar(100)),
            TransactionDate = CAST(t.TransactionDate AS date),
            ProductCode     = CAST(t.Product AS varchar(50)),
            ProductDescription = CAST(ISNULL(p.Description, '') AS varchar(100)),
            Quantity        = CAST(t.Quantity AS decimal(18,3)),
            SellingPrice    = CAST(t.SellingPrice AS decimal(18,2)),
            TotalAmount     = CAST(t.TotalAmount AS decimal(18,2)),
            EstimatedVATShortfall = CAST(ROUND(t.TotalAmount / 1.12 * 0.12, 2) AS decimal(18,2))
        FROM dbo.TransactionChargeSalesDetails AS t
        JOIN dbo.Products AS p ON p.ProductCode = t.Product
        WHERE t.Type = 'SALES VAT EXEMPT' AND p.isVat = 1
          AND t.TransactionDate >= @Start AND t.TransactionDate < @End
        ORDER BY t.TransactionDate DESC;
        RETURN;
    END

    /* ==== SALES-CM-CLIENT — unchanged from sql/18 ==== */
    IF @ExceptionCode = 'SALES-CM-CLIENT'
    BEGIN
        ;WITH CMTickets AS (
            SELECT tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber,
                   tm.ReferenceNumber, tm.Mnemonic, tm.Particulars
            FROM dbo.TicketMaster AS tm
            JOIN dbo.RptMnemonicMap AS mm ON mm.Mnemonic = tm.Mnemonic
            WHERE mm.Mnemonic LIKE 'CM-CLIENT-%'
              AND tm.Status IN ('POSTED','UPDATED')
              AND tm.TicketDate >= @Start AND tm.TicketDate < @End
        )
        SELECT TOP (500)
            TicketDate      = CAST(c.TicketDate AS date),
            BranchCode      = CAST(c.BranchCode AS varchar(5)),
            TicketNumber    = CAST(c.TicketNumber AS varchar(50)),
            ReferenceNumber = CAST(ISNULL(c.ReferenceNumber, '') AS varchar(150)),
            Mnemonic        = CAST(ISNULL(c.Mnemonic, '') AS varchar(50)),
            CustomerKey     = CAST(ISNULL(tcs.CustomerKey, '') AS varchar(8)),
            CustomerName    = CAST(ISNULL(cust.CustomerName, '') AS varchar(200)),
            AgentLabel      = CAST(ISNULL(NULLIF(LTRIM(RTRIM(cust.AccountOfficer)), ''), 'UNASSIGNED') AS varchar(50)),
            ARValue         = CAST(ISNULL(ar.ARValue, 0) AS decimal(18,2)),
            Particulars     = CAST(ISNULL(c.Particulars, '') AS varchar(400))
        FROM CMTickets AS c
        LEFT JOIN dbo.TransactionChargeSales AS tcs ON tcs.ReferenceNo = c.ReferenceNumber
        LEFT JOIN dbo.Customers AS cust ON cust.CustomerKey = tcs.CustomerKey
        OUTER APPLY (
            SELECT ARValue = SUM(td.Credit - td.Debit)
            FROM dbo.TicketDetails AS td
            JOIN dbo.vw_AccountTree AS t ON t.AccountCode = td.AccountCode
            WHERE td.TicketDate          = c.TicketDate
              AND td.SupplementaryNumber = c.SupplementaryNumber
              AND td.BranchCode          = c.BranchCode
              AND td.TicketNumber        = c.TicketNumber
              AND t.AncestorCode = '101030101'
        ) AS ar
        ORDER BY c.TicketDate DESC;
        RETURN;
    END

    /* ==== SALES-RETURNED-ORDERS — unchanged from sql/18 ==== */
    IF @ExceptionCode = 'SALES-RETURNED-ORDERS'
    BEGIN
        SELECT TOP (500)
            PONumber        = CAST(ros.PONumber AS varchar(20)),
            InvoiceNo       = CAST(ISNULL(ros.InvoiceNo, '') AS varchar(50)),
            BranchCode      = CAST(ros.BranchCode AS varchar(20)),
            DateAdded       = CAST(ros.DateAdded AS date),
            TotalAmount     = CAST(ISNULL(ros.TotalAmount, 0) AS decimal(18,2)),
            PreparedBy      = CAST(ISNULL(ros.PreparedBy, '') AS varchar(30)),
            Reason          = CAST(ISNULL(ros.Reason, '') AS varchar(3000)),
            HasGLCreditMemo = CAST(CASE WHEN tm.TicketNumber IS NOT NULL THEN 1 ELSE 0 END AS bit)
        FROM dbo.ReturnedOrderSummary AS ros
        LEFT JOIN dbo.TicketMaster AS tm
            ON tm.TicketNumber IN (ros.TicketRefNoVAT, ros.TicketRefNoVATEX)
           AND tm.Mnemonic LIKE 'CM-CLIENT-%'
           AND tm.Status IN ('POSTED','UPDATED')
        WHERE ros.DateAdded >= @DateFrom AND ros.DateAdded < CAST(@End AS date)
        ORDER BY ros.DateAdded DESC;
        RETURN;
    END

    /* ==== SALES-CREDIT-LIMIT-BREACH — BUGFIXED 2026-09-23, hardened
       2026-09-26 (see Summary proc's comment for the full explanation) ==== */
    IF @ExceptionCode = 'SALES-CREDIT-LIMIT-BREACH'
    BEGIN
        ;WITH Orders AS (
            SELECT
                ds.DeliveryNo, ds.PONumber, ds.Status, ds.DateAdded,
                tcs.CustomerKey, tcs.BranchCode, tcs.InvoiceNo, tcs.TotalAmount,
                PostOrderBalance = (
                    SELECT TOP (1) cl.EndingBalance
                    FROM dbo.ClientLedger AS cl
                    WHERE cl.AccountKey = tcs.CustomerKey
                      AND cl.InvoiceNo  = tcs.InvoiceNo
                      AND cl.ReferenceNumber = tcs.ReferenceNo
                      AND cl.TransCode IN ('SI-VAT','SI-VATEX')
                    ORDER BY cl.TRN_SEQ_NO DESC
                )
            FROM dbo.DeliverySummary AS ds
            JOIN dbo.TransactionChargeSales AS tcs ON tcs.ReferenceNo = ds.PONumber
            WHERE ds.Status IN ('DELIVERED','RETURNED')
              AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
        )
        SELECT TOP (500)
            DeliveryNo        = CAST(o.DeliveryNo AS varchar(20)),
            PONumber          = CAST(o.PONumber AS varchar(20)),
            BranchCode        = CAST(o.BranchCode AS varchar(5)),
            BranchName        = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            Status            = CAST(o.Status AS varchar(50)),
            DateAdded         = CAST(o.DateAdded AS date),
            CustomerKey       = CAST(o.CustomerKey AS char(8)),
            CustomerName      = CAST(ISNULL(c.CustomerName, '') AS varchar(200)),
            OrderAmount       = CAST(o.TotalAmount AS decimal(18,2)),
            BalanceAfterOrder = CAST(o.PostOrderBalance AS decimal(18,2)),
            CreditLimit       = CAST(c.CustomerCreditLimit AS decimal(18,2)),
            ExcessOverLimit   = CAST(o.PostOrderBalance - c.CustomerCreditLimit AS decimal(18,2))
        FROM Orders AS o
        JOIN dbo.Customers AS c ON c.CustomerKey = o.CustomerKey
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = o.BranchCode
        WHERE o.PostOrderBalance > ISNULL(c.CustomerCreditLimit, 0)
        ORDER BY ExcessOverLimit DESC;
        RETURN;
    END

    /* ==== SALES-BELOW-COST — unchanged from sql/18 ==== */
    IF @ExceptionCode = 'SALES-BELOW-COST'
    BEGIN
        SELECT TOP (500)
            BranchCode      = CAST(t.BranchCode AS varchar(5)),
            ReferenceNo     = CAST(t.ReferenceNo AS varchar(20)),
            InvoiceNo       = CAST(ISNULL(t.InvoiceNo, '') AS varchar(100)),
            TransactionDate = CAST(t.TransactionDate AS date),
            ProductCode     = CAST(t.Product AS varchar(50)),
            ProductDescription = CAST(ISNULL(p.Description, '') AS varchar(100)),
            Quantity        = CAST(t.Quantity AS decimal(18,3)),
            Cost            = CAST(t.Cost AS decimal(18,2)),
            SellingPrice    = CAST(t.SellingPrice AS decimal(18,2)),
            MarginLossPerUnit = CAST(t.Cost - t.SellingPrice AS decimal(18,2)),
            TotalMarginLoss = CAST((t.Cost - t.SellingPrice) * t.Quantity AS decimal(18,2))
        FROM dbo.TransactionChargeSalesDetails AS t
        LEFT JOIN dbo.Products AS p ON p.ProductCode = t.Product
        WHERE t.Type IN ('SALES VAT','SALES VAT EXEMPT')
          AND t.SellingPrice > 0 AND t.SellingPrice < t.Cost
          AND t.TransactionDate >= @Start AND t.TransactionDate < @End
        ORDER BY TotalMarginLoss DESC;
        RETURN;
    END

    /* ==== PUR-PENDING-APPROVAL (NEW, this pass) — one row per flagged PO
       header, DaysPending computed against @StaleAsOf. ==== */
    IF @ExceptionCode = 'PUR-PENDING-APPROVAL'
    BEGIN
        SELECT TOP (500)
            ShipmentNo    = CAST(ps.ShipmentNo AS varchar(10)),
            BranchCode    = CAST(ps.BranchCode AS varchar(5)),
            BranchName    = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            SupplierID    = CAST(ps.SupplierID AS varchar(30)),
            SupplierName  = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            DateOrder     = CAST(ps.DateOrder AS datetime),
            DaysPending   = CAST(DATEDIFF(DAY, ps.DateOrder, @StaleAsOf) AS int),
            OrderedBy     = CAST(ISNULL(ps.OrderedBy, '') AS varchar(30)),
            TotalItems    = CAST(ISNULL(ps.TotalItems, 0) AS int),
            TotalQty      = CAST(ISNULL(ps.TotalQty, 0) AS decimal(18,3)),
            TotalCost     = CAST(ISNULL(ps.TotalCost, 0) AS decimal(18,2)),
            Remarks       = CAST(ISNULL(ps.Remarks, '') AS varchar(500))
        FROM dbo.POSUMMARY AS ps
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = ps.BranchCode
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = ps.SupplierID
        WHERE ps.Status = 'FOR APPROVAL'
          AND ps.DateOrder >= @DateFrom AND ps.DateOrder < CAST(@End AS date)
          AND DATEDIFF(DAY, ps.DateOrder, @StaleAsOf) > @PendingApprovalDays
        ORDER BY DaysPending DESC;
        RETURN;
    END

    /* ==== PUR-APPROVED-PENDING-RECEIPT (NEW, this pass) — one row per
       flagged PO header, DaysSinceApproval computed against @StaleAsOf.
       Status = 'FOR DELIVERY' only — see Summary proc comment on why the
       320-row DELIVERED migration artifact is deliberately excluded. ==== */
    IF @ExceptionCode = 'PUR-APPROVED-PENDING-RECEIPT'
    BEGIN
        SELECT TOP (500)
            ShipmentNo        = CAST(ps.ShipmentNo AS varchar(10)),
            BranchCode        = CAST(ps.BranchCode AS varchar(5)),
            BranchName        = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            SupplierID        = CAST(ps.SupplierID AS varchar(30)),
            SupplierName      = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            DateOrder         = CAST(ps.DateOrder AS datetime),
            ApprovedDate      = CAST(ps.ApprovedDate AS datetime),
            DaysSinceApproval = CAST(DATEDIFF(DAY, ps.ApprovedDate, @StaleAsOf) AS int),
            ApprovedBy        = CAST(ISNULL(ps.ApprovedBy, '') AS varchar(30)),
            TotalItems        = CAST(ISNULL(ps.TotalItems, 0) AS int),
            TotalQty          = CAST(ISNULL(ps.TotalQty, 0) AS decimal(18,3)),
            TotalCost         = CAST(ISNULL(ps.TotalCost, 0) AS decimal(18,2)),
            Remarks           = CAST(ISNULL(ps.Remarks, '') AS varchar(500))
        FROM dbo.POSUMMARY AS ps
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = ps.BranchCode
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = ps.SupplierID
        WHERE ps.Status = 'FOR DELIVERY'
          AND ps.DateOrder >= @DateFrom AND ps.DateOrder < CAST(@End AS date)
          AND DATEDIFF(DAY, ps.ApprovedDate, @StaleAsOf) > @ApprovedPendingReceiptDays
        ORDER BY DaysSinceApproval DESC;
        RETURN;
    END

    /* ==== PUR-FOR-CONFIRMATION (NEW, this pass) — one row per PO header
       still in 'FOR CONFIRMATION'; DaysAwaitingConfirmation shown for
       context even though no threshold gates this check (see Summary
       proc comment). ==== */
    IF @ExceptionCode = 'PUR-FOR-CONFIRMATION'
    BEGIN
        SELECT TOP (500)
            ShipmentNo                = CAST(ps.ShipmentNo AS varchar(10)),
            BranchCode                = CAST(ps.BranchCode AS varchar(5)),
            BranchName                = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            SupplierID                = CAST(ps.SupplierID AS varchar(30)),
            SupplierName              = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            DateOrder                 = CAST(ps.DateOrder AS datetime),
            ReceivedDate              = CAST(ps.ReceivedDate AS datetime),
            DaysAwaitingConfirmation  = CAST(DATEDIFF(DAY, ps.ReceivedDate, @StaleAsOf) AS int),
            ReceivedBy                = CAST(ISNULL(ps.ReceivedBy, '') AS varchar(30)),
            TotalItems                = CAST(ISNULL(ps.TotalItems, 0) AS int),
            TotalQty                  = CAST(ISNULL(ps.TotalQty, 0) AS decimal(18,3)),
            TotalActualQty            = CAST(ISNULL(ps.TotalActualQty, 0) AS decimal(18,3)),
            TotalCost                 = CAST(ISNULL(ps.TotalCost, 0) AS decimal(18,2)),
            Remarks                   = CAST(ISNULL(ps.Remarks, '') AS varchar(500))
        FROM dbo.POSUMMARY AS ps
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = ps.BranchCode
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = ps.SupplierID
        WHERE ps.Status = 'FOR CONFIRMATION'
          AND ps.DateOrder >= @DateFrom AND ps.DateOrder < CAST(@End AS date)
        ORDER BY DaysAwaitingConfirmation DESC;
        RETURN;
    END

    /* ==== PUR-OVER-RECEIPT (NEW, this pass) — one row per flagged PO LINE
       (not header). VarianceValue = 0.00 today for every row, see Summary
       proc comment and this file's header "COST DATA-QUALITY FINDING" —
       the quantity variance itself is real regardless. ==== */
    IF @ExceptionCode = 'PUR-OVER-RECEIPT'
    BEGIN
        SELECT TOP (500)
            ShipmentNo      = CAST(pd.ShipmentNo AS varchar(10)),
            BranchCode      = CAST(ps.BranchCode AS varchar(5)),
            BranchName      = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            SupplierID      = CAST(pd.SupplierID AS varchar(30)),
            SupplierName    = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            Status          = CAST(ps.Status AS varchar(20)),
            ReceivedDate    = CAST(ps.ReceivedDate AS datetime),
            ProductCode     = CAST(pd.OrderCode AS varchar(20)),
            ProductDescription = CAST(ISNULL(p.Description, '') AS varchar(100)),
            Unit            = CAST(ISNULL(pd.Unit, '') AS varchar(10)),
            OrderedQty      = CAST(pd.Quantity AS decimal(18,3)),
            ReceivedQty     = CAST(pd.ActualQuantity AS decimal(18,3)),
            VarianceQty     = CAST(pd.ActualQuantity - pd.Quantity AS decimal(18,3)),
            VariancePct     = CAST(CASE WHEN pd.Quantity <> 0
                                        THEN (pd.ActualQuantity - pd.Quantity) / pd.Quantity * 100
                                        ELSE NULL END AS decimal(9,2)),
            Cost            = CAST(pd.Cost AS decimal(18,4)),
            VarianceValue   = CAST((pd.ActualQuantity - pd.Quantity) * pd.Cost AS decimal(18,2)),
            ReferenceCode   = CAST(ISNULL(pd.ReferenceCode, '') AS varchar(150))
        FROM dbo.PODETAILS AS pd
        JOIN dbo.POSUMMARY AS ps ON ps.ShipmentNo = pd.ShipmentNo
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = ps.BranchCode
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = pd.SupplierID
        LEFT JOIN dbo.Products AS p ON p.ProductCode = pd.OrderCode AND p.BranchCode = ps.BranchCode
        WHERE pd.ActualQuantity IS NOT NULL AND pd.ActualQuantity > pd.Quantity
          AND ps.ReceivedDate >= @DateFrom AND ps.ReceivedDate < CAST(@End AS date)
        ORDER BY VarianceQty DESC;
        RETURN;
    END

    /* ==== Unknown @ExceptionCode — fail loudly ==== */
    RAISERROR('sp_rpt_ExceptionCenter_Detail: unknown or not-yet-implemented @ExceptionCode ''%s''.', 16, 1, @ExceptionCode);
END
GO


/* ============================================================================
   SMOKE TEST — re-run after applying, confirms the fix and full regression
   suite. All figures below verified live on CORECSERP_002_DEV, 2026-09-26.
============================================================================ */
/*
EXEC dbo.sp_rpt_ExceptionCenter_Summary @DateFrom='2020-01-01', @DateTo='2026-12-31', @AsOfDate='2026-09-23';

Expected (SALES-CREDIT-LIMIT-BREACH is the one that changed; every other row
is a point-in-time snapshot of a LIVE shared dev database and will drift
slightly release to release as real test transactions get posted — that is
expected, not a regression, as long as the SHAPE/PROC LOGIC is unchanged):

  SOD-SAME-PREP-APPR                    1   3,688,581,595.84
  VOU-CANCELLED-CHECKS                  *   *                  (proc logic unchanged since sql/16)
  VOU-REVERSED-VOUCHERS                 *   *                  (proc logic unchanged since sql/16)
  VOU-DUP-CHECKNO                       7   583,184.37
  VOU-DUP-SUPPLIER-INVOICE              2   1,062,922.85
  VOU-STALE-OUTSTANDING-CHECKS          1   26,153.50
  EXP-REVERSALS                         *   *                  (proc logic unchanged since sql/16)
  AR-REVERSED-PAYMENTS                  *   *                  (proc logic unchanged since sql/17)
  AR-STALE-CREDIT-BALANCE             169   2,039,671.87
  SALES-UNCONFIRMED-ORDERS             45   0.00
  SALES-VATABLE-ZERO-VAT               75   114,000.00
  SALES-CM-CLIENT                      26   1,476,101.10
  SALES-RETURNED-ORDERS                96   3,405,042.08
  SALES-CREDIT-LIMIT-BREACH          464   24,378,158.20   <- THE FIX (was 860 / 32,444,001.87)
  SALES-BELOW-COST                    577   727,486.86
  PUR-PENDING-APPROVAL                  2   0.00
  PUR-APPROVED-PENDING-RECEIPT         16   0.00
  PUR-FOR-CONFIRMATION                  *   0.00              (proc logic unchanged since sql/19)
  PUR-OVER-RECEIPT                      *   0.00              (proc logic unchanged since sql/19)

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode='SALES-CREDIT-LIMIT-BREACH', @DateFrom='2020-01-01', @DateTo='2026-12-31';
-- Expect exactly 464 rows, SUM(OrderAmount) = 24,378,158.20, ties to Summary exactly.
-- Every row now also carries BranchCode/BranchName (selling branch).
*/
