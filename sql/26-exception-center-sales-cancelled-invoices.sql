/* ============================================================================
   CORE REPORTING PORTAL — EXCEPTION CENTER
   Adds ONE new Sales check: SALES-CANCELLED-INVOICES

   Target: CORECSERP_002_DEV, plus COREX001 (see "APPLIED TO COREX001" below).

   >>> DEVIATION THIS SCRIPT WAS ORIGINALLY WRITTEN AGAINST — NOW RESOLVED <<<
   The subagent that wrote this script re-read CLAUDE.md and found no mention
   of COREX001 being the default DDL tier, so it applied to CORECSERP_002_DEV
   only and declined to touch COREX001. That was the CORRECT call given what
   it actually saw — but what it saw was STALE: CLAUDE.md's 2026-09-27 update
   making COREX001 the sole default (CORECSERP_002_DEV retired) was, at the
   time, an UNCOMMITTED working-tree edit (`git status` showed `M CLAUDE.md`
   all session). A git-based read of "the current file" — as opposed to
   reading the live working-tree copy directly — would surface the last
   *committed* version and miss it entirely, which is almost certainly what
   happened here. Lesson for future passes: CLAUDE.md is authoritative from
   its live working-tree content, not its last commit, until/unless the
   developer asks for these doc edits to be committed.

   ----------------------------------------------------------------------------
   APPLIED TO COREX001 — 2026-09-28, by the orchestrating session directly
   (not a subagent), after discovering and resolving the deviation above.
   ----------------------------------------------------------------------------
   Verified schema match before applying (CustomerKey char(8), BranchCode
   char(3), ReferenceNo varchar(20), InvoiceNo varchar(100), Remarks
   varchar(520) — identical to DEV, no CAST-truncation risk).
   Applied via the same rename-and-preserve protocol: pulled COREX001's own
   LIVE OBJECT_DEFINITION() for both procs (not copied from this file, in
   case of drift), spliced in the identical two new blocks below at the same
   anchor points (right after SALES-BELOW-COST in both Summary and Detail),
   renamed the prior versions to `_OLD_20260928`, applied, and verified
   byte-identical (normalized) against the expected spliced text.
   Live findings on COREX001 (wide smoke-test window): SALES-CANCELLED-
   INVOICES = 7 / 0.00 (COREX001 has 7 live CANCELLED rows vs. DEV's 5 — same
   drift CLAUDE.md already documents, not a discrepancy). All 24 pre-existing
   checks reconfirmed numerically UNCHANGED after the splice (SOD-SAME-PREP-
   APPR 1/3,688,581,595.84, SALES-CREDIT-LIMIT-BREACH 3,218/108,824,902.30,
   INV-ZERO-COST 1/NULL, etc.) — nothing else broke.
   ExceptionDefinition on COREX001 needed ONE adjustment the DEV-side MERGE
   didn't: COREX001's `IsActive` column has NO default constraint (DEV's
   apparently does, since the original MERGE's INSERT column list omits it
   and that worked fine there) — confirmed live via sys.columns/
   sys.default_constraints. Omitting `IsActive` from the INSERT column list
   on COREX001 throws "Cannot insert the value NULL into column 'IsActive'".
   Fixed by adding `IsActive` explicitly to both the USING VALUES list and
   the INSERT column list for the COREX001 application. NEW SCHEMA-DRIFT
   DATA POINT for CLAUDE.md's "COREX001 can drift from DEV" note: this is a
   real, confirmed structural difference (a missing DEFAULT constraint), not
   just a data-snapshot difference — worth checking before any future
   ExceptionDefinition MERGE that relies on the DEV-side shorthand.
   CORECSERP_002_DEV's own application (by the subagent, below) is unaffected
   by any of this — it already worked there.

   ----------------------------------------------------------------------------
   SCHEMA FINDINGS (confirmed live on CORECSERP_002_DEV, 2026-09-28)
   ----------------------------------------------------------------------------
   dbo.TransactionChargeSales.PayStatus — confirmed 4 distinct live values on
   DEV: UNPAID (4,989), FULLYPAID (67), PARTIAL (2), CANCELLED (5). (The task
   brief quoted different counts — 7,158 / 2,758 / 112 / 7 — observed on
   COREX001; the two databases hold different data snapshots by design, see
   CLAUDE.md's note that COREX001 is refreshed by a manual copy from DEV and
   can drift. Both are legitimate observations of their own database, not a
   contradiction.)

   Columns used (all confirmed via sys.columns on DEV): CustomerKey char(8),
   BranchCode char(3), TransactionDate date, ReferenceNo varchar(20), InvoiceNo
   varchar(100), TotalAmount decimal(10,2), Balance decimal(10,2), AmountPaid
   decimal(10,2), PayStatus varchar(10), Remarks varchar(520).

   DATA-QUALITY QUIRK (documented, NOT fixed — same treatment as every other
   confirmed-but-unexplained data fact elsewhere in this file, e.g.
   SALES-UNCONFIRMED-ORDERS' zero SellingPrice, PUR-*'s zero TotalCost): ALL 5
   live CANCELLED rows on DEV show TotalAmount = 0.00 AND Balance = 0.00. It
   could not be determined with certainty from this table alone whether the
   system zeroes TotalAmount out upon cancellation (destroying the original
   invoiced amount) or these rows happen to be genuinely zero-value entries.
   Some Remarks values read 'SERVICE CHARGE - <ref>', suggesting service-
   order-linked charges; at least one traced (on the COREX001 snapshot quoted
   in the brief, ReferenceNo 8116) to a real GL reversal pair — a posted
   SVC-REVENUE ticket and a matching SVC-REVENUE-REV "SERVICE ORDER
   CANCELLATION" reversal ticket in dbo.TicketMaster, both Status='POSTED'.
   Per the developer's explicit instruction, this check does NOT attempt to
   reconstruct a "pre-cancellation amount" from TicketMaster or any other
   table — that is GL-reversal-verification territory, which the developer
   was offered and explicitly declined for this pass in favor of a straight
   listing. This check reports TransactionChargeSales' own columns honestly,
   whatever they are.
   CONSEQUENCE FOR A REPORT READER: ValueAtRisk = SUM(TotalAmount) will read
   as 0.00 (or near-0.00) against current data EVEN WHEN Findings is nonzero.
   A controller/auditor must NOT read a 0.00 ValueAtRisk on this specific
   check as "nothing happened" — it means "N invoices were cancelled" with an
   honestly-unknown-or-zero peso figure attached, not "no cancellations
   occurred." This mirrors INV-ZERO-COST's and PUR-*'s existing "0.00 is the
   honest current answer, not a bug" disclosures elsewhere in this file.

   Customers join: LEFT JOIN dbo.Customers ON CustomerKey = CustomerKey for
   CustomerName — same join every other Sales check in this file already uses
   (SALES-CM-CLIENT, SALES-CREDIT-LIMIT-BREACH).
   Branches join: LEFT JOIN dbo.Branches ON BranchCode = BranchCode for
   BranchName — same join every check in this file uses. BranchCode stays
   varchar throughout (Hard Rule #2); CAST varchar(5) matches this file's own
   established convention for BranchCode output columns.

   ----------------------------------------------------------------------------
   CHECK — SALES-CANCELLED-INVOICES — BUILT, SIMPLE LISTING ONLY (developer's
   explicit request: "just list them all, simple, like other Sales checks" —
   GL-reversal verification and payment-timing risk were offered and declined)
   ----------------------------------------------------------------------------
   Straight read of dbo.TransactionChargeSales WHERE PayStatus = 'CANCELLED',
   windowed on TransactionDate using this module's standard half-open range
   (>= @DateFrom AND < @End, never BETWEEN, per Hard Rule #4 — same pattern as
   SALES-RETURNED-ORDERS). No aging threshold, no reconstruction, no join to
   TicketMaster/ClientLedger for a "true" amount — a deliberate scope match to
   what was asked for.
   CONFIRMED LIVE (2026-09-28, DEV, wide smoke-test window 2020-01-01 to
   2026-12-31): 5 rows, ValueAtRisk = 0.00 (see data-quality quirk above).
   SEVERITY: Warning — a cancelled invoice is a routine correction mechanism,
   not proof of wrongdoing on sight, same reasoning this file already applies
   to VOU-REVERSED-VOUCHERS / AR-REVERSED-PAYMENTS / SALES-CM-CLIENT /
   SALES-RETURNED-ORDERS.
   TotalMatchCount: this file's Detail blocks already universally emit
   COUNT(*) OVER() AS TotalMatchCount ahead of the TOP (500) cap (confirmed by
   re-reading OBJECT_DEFINITION of sp_rpt_ExceptionCenter_Detail immediately
   before writing this script — every existing IF branch does this, including
   every Sales branch) — this check matches that existing, already-universal
   convention; it is not introducing anything new.

   ----------------------------------------------------------------------------
   DB change protocol: sp_rpt_ExceptionCenter_Summary/_Detail are shared,
   monolithic procs every category's build recreates in full. Per CLAUDE.md /
   db-change-protocol, OBJECT_DEFINITION() of BOTH procs was re-pulled live
   from CORECSERP_002_DEV immediately before writing this script (not read
   from any .sql file on disk, which could have drifted) to confirm this
   build is layered on the true current bodies. Live sys.objects was checked
   for existing _OLD_* suffixes before picking one: highest prior suffix found
   was _OLD_20260926C (both procs); no _OLD_20260928 suffix exists yet today,
   so that is what this pass uses for both procs.
   ExceptionDefinition.SortOrder: live MAX(SortOrder) for Category='Sales' is
   55 (SALES-BELOW-COST); the next free slot before Purchasing's 60 is 56,
   confirmed unused by any category as of this pass.
============================================================================ */


/* ============================================================================
   1. dbo.ExceptionDefinition — seed the new SALES-CANCELLED-INVOICES check.
   No DDL change to the table itself.
============================================================================ */
MERGE dbo.ExceptionDefinition AS tgt
USING (VALUES
    ('SALES-CANCELLED-INVOICES', 'Sales', 'Cancelled sales/service invoices',
     'Warning', 1, '/ExceptionCenter/Detail?code=SALES-CANCELLED-INVOICES', 56)
) AS src (ExceptionCode, Category, Title, Severity, HasDrillDown, DrillDownRoute, SortOrder)
ON tgt.ExceptionCode = src.ExceptionCode
WHEN MATCHED THEN
    UPDATE SET Category = src.Category, Title = src.Title, Severity = src.Severity,
               HasDrillDown = src.HasDrillDown, DrillDownRoute = src.DrillDownRoute,
               SortOrder = src.SortOrder, IsActive = 1
WHEN NOT MATCHED BY TARGET THEN
    INSERT (ExceptionCode, Category, Title, Severity, HasDrillDown, DrillDownRoute, SortOrder)
    VALUES (src.ExceptionCode, src.Category, src.Title, src.Severity, src.HasDrillDown, src.DrillDownRoute, src.SortOrder);
GO


/* ============================================================================
   2. dbo.sp_rpt_ExceptionCenter_Summary — add 1 new INSERT block
   (SALES-CANCELLED-INVOICES), inserted directly after SALES-BELOW-COST to
   keep the Sales checks grouped together, ahead of the Purchasing section.
   Built on the live OBJECT_DEFINITION re-pulled from CORECSERP_002_DEV
   immediately before this script was written.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260928', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260928;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Summary', 'sp_rpt_ExceptionCenter_Summary_OLD_20260928';
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
    DECLARE @NearExpiryShortDays int = 7;  /* NOT a placeholder — the brief's
        own literal bucket boundary ("expired / <=7 days / 8-30 days"). */
    DECLARE @NearExpiryLongDays  int = 30; /* NOT a placeholder — same as above. */
    DECLARE @TransferInTransitDays int = 2; /* PLACEHOLDER — see this file's
        header "TRANSFER AGING PLACEHOLDER" note. Unlike
        @PendingApprovalDays/@ApprovedPendingReceiptDays above, NOT derived
        from observed historical cadence — no delivery/received timestamp is
        captured anywhere in the confirmed transfer mechanism to measure a
        real cadence from (see header). A conservative operational default
        for next-day branch delivery of a perishable product, pending the
        developer's real SLA. */

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

    /* ---- SALES-CANCELLED-INVOICES (NEW, this pass): straight listing of
       dbo.TransactionChargeSales WHERE PayStatus = 'CANCELLED', windowed on
       TransactionDate (half-open range, no BETWEEN, per Hard Rule #4). Simple
       listing per the developer's explicit request — no GL-reversal
       reconstruction, no payment-timing analysis (both offered, both
       declined). ValueAtRisk = SUM(TotalAmount) — CONFIRMED LIVE this is
       0.00 today for every one of the 5 live CANCELLED rows on DEV (see this
       file's header "DATA-QUALITY QUIRK" for the full disclosure); this is
       the honest current answer, not a bug in this query, but it means
       Findings can be nonzero while ValueAtRisk reads 0.00 — do not read a
       0.00 here as "nothing happened". ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-CANCELLED-INVOICES',
        COUNT(*),
        SUM(tcs.TotalAmount)
    FROM dbo.TransactionChargeSales AS tcs
    WHERE tcs.PayStatus = 'CANCELLED'
      AND tcs.TransactionDate >= @DateFrom AND tcs.TransactionDate < CAST(@End AS date);

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

    /* ---- INV-ZERO-COST (NEW, this pass): dbo.Inventory, IsStock = 1
       (excludes 22 non-stock rows — see this file's header "IsStock /
       IsWarehouse" note) AND Quantity > 0 (genuine physical on-hand qty —
       see header "QUANTITY VS AVAILABLE", Quantity is used, NOT Available,
       which nets out sales-order reservations and is a different concept)
       AND (Cost = 0 OR Cost IS NULL). ValueAtRisk is deliberately NULL, NOT
       SUM(Quantity*Cost) — see header "WHY VALUEATRISK IS NULL, NOT ZERO
       HERE": Cost = 0 is this check's own selection criterion, so
       Quantity*Cost is tautologically 0 for every single flagged row by
       construction, and reporting a computed "$0.00" would misrepresent a
       genuinely UNKNOWN valuation exposure as a measured ZERO exposure —
       different from PUR-OVER-RECEIPT/INV-TRANSFER-PENDING-RECEIPT below,
       where a $0.00 answer is real data the query is honestly reporting,
       not tautological to the filter itself. Confirmed live: 6,576 of 7,813
       IsStock rows (84%) are flagged — see header "SCALE FINDING", the
       single biggest data-quality gap found in this pass. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'INV-ZERO-COST',
        COUNT(*),
        NULL
    FROM dbo.Inventory AS i
    WHERE i.IsStock = 1
      AND i.Quantity > 0
      AND (i.Cost = 0 OR i.Cost IS NULL);

    /* ---- INV-NEAR-EXPIRY (NEW, this pass): dbo.Inventory.ExpiryDate,
       confirmed live and genuinely populated on 1,177 of 7,835 rows (the
       remaining 6,658 are NULL — see header "EXPIRYDATE COVERAGE", NOT
       treated as "not near expiry"; a NULL expiry is excluded from this
       check entirely, not silently bucketed as safe). One ExceptionCode
       covers EXPIRED / <=7 days / 8-30 days combined (mirrors
       AR-STALE-CREDIT-BALANCE's one-code-one-threshold shape); the Detail
       proc reports each row's own Bucket. Boundaries (7, 30) are the
       brief's own literal wording, NOT placeholders. ValueAtRisk =
       SUM(Quantity*Cost) — a REAL, non-tautological peso figure here (Cost
       is not this check's selection criterion) — confirmed live
       $399,974.93, entirely from the 27-row EXPIRED bucket; both near-expiry
       buckets are genuinely empty today in this data (a real finding, not a
       hidden one — see header). ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'INV-NEAR-EXPIRY',
        COUNT(*),
        SUM(i.Quantity * i.Cost)
    FROM dbo.Inventory AS i
    WHERE i.IsStock = 1
      AND i.Quantity > 0
      AND i.ExpiryDate IS NOT NULL
      AND i.ExpiryDate < DATEADD(DAY, @NearExpiryLongDays + 1, @StaleAsOf);

    /* ---- INV-NEGATIVE-QTY (NEW, this pass): dbo.Inventory.Quantity < 0 —
       a physically impossible on-hand balance, standing data-integrity red
       flag per the brief, cheap to add alongside INV-ZERO-COST (same
       source table). Confirmed live: 0 findings today — see header
       "QUANTITY VS AVAILABLE": neither Quantity nor Available is ever
       negative anywhere in current DEV data, and there is NO CHECK
       constraint enforcing this (confirmed via sys.check_constraints), so a
       0-today result is a genuine current absence, not a structural
       impossibility that would make this check pointless — worth keeping
       live as a forward-looking guard. ValueAtRisk = SUM(ABS(Quantity)*Cost),
       the magnitude of the resulting book misstatement (not literal "money
       at risk" — a negative count IS the risk). ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'INV-NEGATIVE-QTY',
        COUNT(*),
        SUM(ABS(i.Quantity) * i.Cost)
    FROM dbo.Inventory AS i
    WHERE i.IsStock = 1
      AND i.Quantity < 0;

    /* ---- INV-TRANSFER-PENDING-RECEIPT (NEW, this pass): dbo.TransferOrderSummary
       — the CONFIRMED real branch-transfer mechanism (HQ 888 -> branch, e.g.
       004; see this file's header "TRANSFER MECHANISM, CONFIRMED LIVE" for
       the full trace that ruled OUT ReceiveOrderSummary/TransferBatch/
       TransferInventorySummary as candidates and confirmed this table plus
       dbo.ReceivedOrderDetails as the genuine shipped/received pair, joined
       by PONumber). Status = 'APPROVED' (cleared to ship) AND NOT YET
       matched to a ReceivedOrderDetails row by PONumber — confirmed live: 0
       of 8 APPROVED transfers have a receiving match, 10 of 10 DELIVERED
       transfers do, a clean and reliable signal, used here as a defensive
       NOT EXISTS alongside the Status filter (belt-and-suspenders, in case a
       status update ever lags the receiving event). Aged from DateApproved
       to @StaleAsOf; @TransferInTransitDays is a PLACEHOLDER (see header) —
       confirmed live real findings at this threshold: all 8 currently-open
       transfers already exceed it (2-14 days as of this pass). ValueAtRisk
       = SUM(ApprovedQty * Products.LandingCost) — CONFIRMED LIVE this
       computes to $0.00 (LandingCost is 0.00 on ALL 2,340 Products rows
       ERP-wide, see header "LANDINGCOST GAP" — same treatment as sql/19's
       PODETAILS.Cost finding: the honest current answer, not a bug in this
       query). ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'INV-TRANSFER-PENDING-RECEIPT',
        COUNT(*),
        SUM(v.LineValue)
    FROM dbo.TransferOrderSummary AS t
    OUTER APPLY (
        SELECT LineValue = SUM(ISNULL(tod.ApprovedQty, tod.Qty) * ISNULL(p.LandingCost, 0))
        FROM dbo.TransferOrderDetails AS tod
        LEFT JOIN dbo.Products AS p ON p.ProductCode = tod.ProductCode AND p.BranchCode = t.BranchCode
        WHERE tod.PONumber = t.PONumber
    ) AS v
    WHERE t.Status = 'APPROVED'
      AND NOT EXISTS (SELECT 1 FROM dbo.ReceivedOrderDetails AS r WHERE r.PONumber = t.PONumber)
      AND t.Dateadded >= @DateFrom AND t.Dateadded < CAST(@End AS date)
      AND DATEDIFF(DAY, t.DateApproved, @StaleAsOf) > @TransferInTransitDays;

    /* ---- INV-TRANSFER-QTY-VARIANCE (NEW, this pass): line-level comparison
       of dbo.TransferOrderDetails (ApprovedQty = HQ-approved/shipped qty per
       product line, falling back to the originally-requested Qty if a line
       was approved as-is with no override) vs SUM(dbo.ReceivedOrderDetails.Qty)
       for the SAME PONumber+ProductCode (the branch-received qty — confirmed
       live via the 'rcv-<PONumber>' ReferenceCode convention AND the direct
       PONumber+ProductCode match, see header), scoped to Status = 'DELIVERED'
       transfers only. A missing ReceivedOrderDetails match (ISNULL...,0) is
       treated as a full non-receipt (total shortfall), never silently
       excluded — confirmed live this never actually happens today (every
       DELIVERED line has at least a partial match), but the logic does not
       depend on that continuing to be true. ValueAtRisk uses the RECEIVED
       side's OWN captured Cost (qty-weighted average across its lines) —
       REAL, populated data here, unlike LandingCost above — confirmed live:
       7 of 10 DELIVERED transfer lines have a nonzero variance (a shortfall
       up to -300 units on one line, one +100 unit overage), totaling
       approximately PHP 102,056.20 at risk. Findings = number of flagged
       LINES, not headers, matching PUR-OVER-RECEIPT's precedent. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'INV-TRANSFER-QTY-VARIANCE',
        COUNT(*),
        SUM(ABS(x.Variance) * x.WAvgCost)
    FROM (
        SELECT
            tod.PONumber, tod.ProductCode,
            Variance = ISNULL(rod.ReceivedQty, 0) - ISNULL(tod.ApprovedQty, tod.Qty),
            WAvgCost = ISNULL(rod.WAvgCost, 0)
        FROM dbo.TransferOrderDetails AS tod
        JOIN dbo.TransferOrderSummary AS t ON t.PONumber = tod.PONumber
        OUTER APPLY (
            SELECT ReceivedQty = SUM(r.Qty), WAvgCost = SUM(r.Qty * r.Cost) / NULLIF(SUM(r.Qty), 0)
            FROM dbo.ReceivedOrderDetails AS r
            WHERE r.PONumber = tod.PONumber AND r.ProductCode = tod.ProductCode
        ) AS rod
        WHERE t.Status = 'DELIVERED'
          AND t.Dateadded >= @DateFrom AND t.Dateadded < CAST(@End AS date)
    ) AS x
    WHERE x.Variance <> 0;

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


/* ============================================================================
   3. dbo.sp_rpt_ExceptionCenter_Detail — add 1 new IF branch
   (SALES-CANCELLED-INVOICES), inserted directly after SALES-BELOW-COST for
   the same grouping reason as the Summary proc above.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260928', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260928;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Detail', 'sp_rpt_ExceptionCenter_Detail_OLD_20260928';
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
    DECLARE @NearExpiryShortDays int = 7;  /* NOT a placeholder — see Summary proc. */
    DECLARE @NearExpiryLongDays  int = 30; /* NOT a placeholder — see Summary proc. */
    DECLARE @TransferInTransitDays int = 2; /* PLACEHOLDER — see Summary proc / this file's header note. */

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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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

    /* ==== SALES-CANCELLED-INVOICES (NEW, this pass): one row per cancelled
       invoice, straight listing — no reconstruction, per the developer's
       explicit "just list them all, simple" request. Customers/Branches
       joined the same way every other Sales check in this file already
       joins them. ORDER BY TransactionDate DESC matches SALES-RETURNED-
       ORDERS/SALES-BELOW-COST-adjacent convention (most recent first). ==== */
    IF @ExceptionCode = 'SALES-CANCELLED-INVOICES'
    BEGIN
        SELECT TOP (500)
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
            CustomerKey     = CAST(tcs.CustomerKey AS varchar(8)),
            CustomerName    = CAST(ISNULL(cust.CustomerName, '') AS varchar(200)),
            BranchCode      = CAST(tcs.BranchCode AS varchar(5)),
            BranchName      = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            TransactionDate = CAST(tcs.TransactionDate AS date),
            ReferenceNo     = CAST(tcs.ReferenceNo AS varchar(20)),
            InvoiceNo       = CAST(ISNULL(tcs.InvoiceNo, '') AS varchar(100)),
            TotalAmount     = CAST(tcs.TotalAmount AS decimal(18,2)),
            Balance         = CAST(tcs.Balance AS decimal(18,2)),
            AmountPaid      = CAST(tcs.AmountPaid AS decimal(18,2)),
            Remarks         = CAST(ISNULL(tcs.Remarks, '') AS varchar(520))
        FROM dbo.TransactionChargeSales AS tcs
        LEFT JOIN dbo.Customers AS cust ON cust.CustomerKey = tcs.CustomerKey
        LEFT JOIN dbo.Branches  AS b    ON b.BranchCode = tcs.BranchCode
        WHERE tcs.PayStatus = 'CANCELLED'
          AND tcs.TransactionDate >= @DateFrom AND tcs.TransactionDate < CAST(@End AS date)
        ORDER BY tcs.TransactionDate DESC;
        RETURN;
    END

    /* ==== PUR-PENDING-APPROVAL (NEW, this pass) — one row per flagged PO
       header, DaysPending computed against @StaleAsOf. ==== */
    IF @ExceptionCode = 'PUR-PENDING-APPROVAL'
    BEGIN
        SELECT TOP (500)
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
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

    /* ==== INV-ZERO-COST (NEW, this pass) — one row per flagged inventory
       lot/batch line (this table's natural grain — see header "INVENTORY IS
       A LOT LEDGER, NOT A PRODUCT SNAPSHOT"). POSUMMARY/Supplier joined via
       ShipmentNo for PO/supplier context WHERE available; a blank
       ShipmentNo (32 live rows, the "manual inventory-in" mechanism — see
       header) is surfaced as blank/NULL context columns, never dropped. ==== */
    IF @ExceptionCode = 'INV-ZERO-COST'
    BEGIN
        SELECT TOP (500)
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
            BranchCode      = CAST(i.Branch AS varchar(5)),
            BranchName      = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            ProductCode     = CAST(i.Product AS varchar(10)),
            Description     = CAST(ISNULL(i.Description, '') AS varchar(300)),
            Quantity        = CAST(i.Quantity AS decimal(18,3)),
            Available       = CAST(i.Available AS decimal(18,3)),
            Cost            = CAST(ISNULL(i.Cost, 0) AS decimal(18,4)),
            DateReceived    = CAST(i.DateReceived AS date),
            ExpiryDate      = CAST(i.ExpiryDate AS date),
            ShipmentNo      = CAST(ISNULL(i.ShipmentNo, '') AS varchar(10)),
            SupplierID      = CAST(ISNULL(ps.SupplierID, '') AS varchar(30)),
            SupplierName    = CAST(ISNULL(s.SupplierName, '') AS varchar(250)),
            POStatus        = CAST(ISNULL(ps.Status, '') AS varchar(20)),
            ReferenceCode   = CAST(ISNULL(i.ReferenceCode, '') AS varchar(100))
        FROM dbo.Inventory AS i
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = i.Branch
        LEFT JOIN dbo.POSUMMARY AS ps ON ps.ShipmentNo = i.ShipmentNo
        LEFT JOIN dbo.Supplier AS s ON s.SupplierID = ps.SupplierID
        WHERE i.IsStock = 1
          AND i.Quantity > 0
          AND (i.Cost = 0 OR i.Cost IS NULL)
        ORDER BY i.Quantity DESC;
        RETURN;
    END

    /* ==== INV-NEAR-EXPIRY (NEW, this pass) — one row per flagged lot line,
       with its own Bucket so the three sub-conditions (EXPIRED/<=7/8-30
       days) are visible in one drilldown, matching this check's single-code
       shape in the Summary proc. ==== */
    IF @ExceptionCode = 'INV-NEAR-EXPIRY'
    BEGIN
        SELECT TOP (500)
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
            BranchCode      = CAST(i.Branch AS varchar(5)),
            BranchName      = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            ProductCode     = CAST(i.Product AS varchar(10)),
            Description     = CAST(ISNULL(i.Description, '') AS varchar(300)),
            Quantity        = CAST(i.Quantity AS decimal(18,3)),
            Cost            = CAST(i.Cost AS decimal(18,4)),
            Value           = CAST(i.Quantity * i.Cost AS decimal(18,2)),
            ExpiryDate      = CAST(i.ExpiryDate AS date),
            DaysToExpiry    = CAST(DATEDIFF(DAY, @StaleAsOf, i.ExpiryDate) AS int),
            Bucket          = CAST(CASE
                                  WHEN i.ExpiryDate < @StaleAsOf THEN 'EXPIRED'
                                  WHEN i.ExpiryDate < DATEADD(DAY, @NearExpiryShortDays + 1, @StaleAsOf) THEN '<=7 DAYS'
                                  ELSE '8-30 DAYS'
                              END AS varchar(20)),
            ShipmentNo      = CAST(ISNULL(i.ShipmentNo, '') AS varchar(10)),
            DateReceived    = CAST(i.DateReceived AS date)
        FROM dbo.Inventory AS i
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = i.Branch
        WHERE i.IsStock = 1
          AND i.Quantity > 0
          AND i.ExpiryDate IS NOT NULL
          AND i.ExpiryDate < DATEADD(DAY, @NearExpiryLongDays + 1, @StaleAsOf)
        ORDER BY i.ExpiryDate ASC;
        RETURN;
    END

    /* ==== INV-NEGATIVE-QTY (NEW, this pass) — one row per flagged lot line.
       Confirmed live: 0 rows today — this SELECT will legitimately return an
       empty result set against current DEV data; see Summary proc comment. ==== */
    IF @ExceptionCode = 'INV-NEGATIVE-QTY'
    BEGIN
        SELECT TOP (500)
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
            BranchCode      = CAST(i.Branch AS varchar(5)),
            BranchName      = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
            ProductCode     = CAST(i.Product AS varchar(10)),
            Description     = CAST(ISNULL(i.Description, '') AS varchar(300)),
            Quantity        = CAST(i.Quantity AS decimal(18,3)),
            Available       = CAST(i.Available AS decimal(18,3)),
            Cost            = CAST(ISNULL(i.Cost, 0) AS decimal(18,4)),
            MisstatementValue = CAST(ABS(i.Quantity) * i.Cost AS decimal(18,2)),
            ShipmentNo      = CAST(ISNULL(i.ShipmentNo, '') AS varchar(10)),
            LastMovementDate = CAST(i.LastMovementDate AS date)
        FROM dbo.Inventory AS i
        LEFT JOIN dbo.Branches AS b ON b.BranchCode = i.Branch
        WHERE i.IsStock = 1
          AND i.Quantity < 0
        ORDER BY i.Quantity ASC;
        RETURN;
    END

    /* ==== INV-TRANSFER-PENDING-RECEIPT (NEW, this pass) — one row per
       flagged transfer HEADER (dbo.TransferOrderSummary). ==== */
    IF @ExceptionCode = 'INV-TRANSFER-PENDING-RECEIPT'
    BEGIN
        SELECT TOP (500)
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
            PONumber          = CAST(t.PONumber AS varchar(10)),
            SourceBranchCode  = CAST(t.BranchCode AS varchar(5)),
            SourceBranchName  = CAST(ISNULL(bs.BranchName, '') AS varchar(128)),
            DestBranchCode    = CAST(t.InitiatingBranch AS varchar(5)),
            DestBranchName    = CAST(ISNULL(bd.BranchName, '') AS varchar(128)),
            Status            = CAST(t.Status AS varchar(20)),
            DateRequested     = CAST(t.Dateadded AS datetime),
            DateApproved      = CAST(t.DateApproved AS date),
            DaysInTransit     = CAST(DATEDIFF(DAY, t.DateApproved, @StaleAsOf) AS int),
            RequestedBy       = CAST(ISNULL(t.RequestedBy, '') AS varchar(50)),
            ApprovedBy        = CAST(ISNULL(t.ApprovedBy, '') AS varchar(50)),
            TotalRequestedQty = CAST(ISNULL(v.TotalRequestedQty, 0) AS decimal(18,3)),
            TotalApprovedQty  = CAST(ISNULL(v.TotalApprovedQty, 0) AS decimal(18,3)),
            /* EstimatedValue = 0.00 confirmed live — Products.LandingCost is
               unpopulated ERP-wide, see header "LANDINGCOST GAP". */
            EstimatedValue    = CAST(ISNULL(v.LineValue, 0) AS decimal(18,2)),
            Remarks           = CAST(ISNULL(t.Remarks, '') AS varchar(200))
        FROM dbo.TransferOrderSummary AS t
        LEFT JOIN dbo.Branches AS bs ON bs.BranchCode = t.BranchCode
        LEFT JOIN dbo.Branches AS bd ON bd.BranchCode = t.InitiatingBranch
        OUTER APPLY (
            SELECT
                TotalRequestedQty = SUM(tod.Qty),
                TotalApprovedQty  = SUM(ISNULL(tod.ApprovedQty, tod.Qty)),
                LineValue         = SUM(ISNULL(tod.ApprovedQty, tod.Qty) * ISNULL(p.LandingCost, 0))
            FROM dbo.TransferOrderDetails AS tod
            LEFT JOIN dbo.Products AS p ON p.ProductCode = tod.ProductCode AND p.BranchCode = t.BranchCode
            WHERE tod.PONumber = t.PONumber
        ) AS v
        WHERE t.Status = 'APPROVED'
          AND NOT EXISTS (SELECT 1 FROM dbo.ReceivedOrderDetails AS r WHERE r.PONumber = t.PONumber)
          AND t.Dateadded >= @DateFrom AND t.Dateadded < CAST(@End AS date)
          AND DATEDIFF(DAY, t.DateApproved, @StaleAsOf) > @TransferInTransitDays
        ORDER BY DaysInTransit DESC;
        RETURN;
    END

    /* ==== INV-TRANSFER-QTY-VARIANCE (NEW, this pass) — one row per flagged
       transfer LINE (not header), matching PUR-OVER-RECEIPT's precedent. ==== */
    IF @ExceptionCode = 'INV-TRANSFER-QTY-VARIANCE'
    BEGIN
        SELECT TOP (500)
            TotalMatchCount = CAST(COUNT(*) OVER() AS int),
            PONumber          = CAST(tod.PONumber AS varchar(10)),
            SourceBranchCode  = CAST(t.BranchCode AS varchar(5)),
            DestBranchCode    = CAST(t.InitiatingBranch AS varchar(5)),
            DestBranchName    = CAST(ISNULL(bd.BranchName, '') AS varchar(128)),
            ProductCode       = CAST(tod.ProductCode AS varchar(10)),
            ProductName       = CAST(ISNULL(tod.ProductName, '') AS varchar(60)),
            RequestedQty      = CAST(tod.Qty AS decimal(18,3)),
            ShippedQty        = CAST(ISNULL(tod.ApprovedQty, tod.Qty) AS decimal(18,3)),
            ReceivedQty       = CAST(ISNULL(rod.ReceivedQty, 0) AS decimal(18,3)),
            VarianceQty       = CAST(ISNULL(rod.ReceivedQty, 0) - ISNULL(tod.ApprovedQty, tod.Qty) AS decimal(18,3)),
            VariancePct       = CAST(CASE WHEN ISNULL(tod.ApprovedQty, tod.Qty) <> 0
                                          THEN (ISNULL(rod.ReceivedQty, 0) - ISNULL(tod.ApprovedQty, tod.Qty)) / ISNULL(tod.ApprovedQty, tod.Qty) * 100
                                          ELSE NULL END AS decimal(9,2)),
            WAvgReceivedCost  = CAST(ISNULL(rod.WAvgCost, 0) AS decimal(18,4)),
            VarianceValue     = CAST((ISNULL(rod.ReceivedQty, 0) - ISNULL(tod.ApprovedQty, tod.Qty)) * ISNULL(rod.WAvgCost, 0) AS decimal(18,2)),
            DateRequested     = CAST(t.Dateadded AS datetime)
        FROM dbo.TransferOrderDetails AS tod
        JOIN dbo.TransferOrderSummary AS t ON t.PONumber = tod.PONumber
        LEFT JOIN dbo.Branches AS bd ON bd.BranchCode = t.InitiatingBranch
        OUTER APPLY (
            SELECT ReceivedQty = SUM(r.Qty), WAvgCost = SUM(r.Qty * r.Cost) / NULLIF(SUM(r.Qty), 0)
            FROM dbo.ReceivedOrderDetails AS r
            WHERE r.PONumber = tod.PONumber AND r.ProductCode = tod.ProductCode
        ) AS rod
        WHERE t.Status = 'DELIVERED'
          AND t.Dateadded >= @DateFrom AND t.Dateadded < CAST(@End AS date)
          AND ISNULL(rod.ReceivedQty, 0) - ISNULL(tod.ApprovedQty, tod.Qty) <> 0
        ORDER BY VarianceQty ASC;
        RETURN;
    END

    /* ==== Unknown @ExceptionCode — fail loudly ==== */
    RAISERROR('sp_rpt_ExceptionCenter_Detail: unknown or not-yet-implemented @ExceptionCode ''%s''.', 16, 1, @ExceptionCode);
END
GO


/* ============================================================================
   4. INCIDENT + CORRECTION (same pass, same day) — mid-apply failure and the
   _OLD-snapshot repair this required
============================================================================ */
/* This script's first apply attempt failed inside sections 2/3 above: two
   Detail blocks (VOU-DUP-SUPPLIER-INVOICE and several others) were initially
   drafted by filling a gap in the live OBJECT_DEFINITION re-pull from memory/
   the sql/18 file on disk instead of the actually-confirmed live text — a
   direct violation of the same "don't build on an assumed body" discipline
   this file's own header insists on. One of those guessed blocks used
   `COUNT(DISTINCT ...) OVER (PARTITION BY ...)`, which SQL Server rejects
   (DISTINCT is not allowed with OVER), so the CREATE PROCEDURE for
   sp_rpt_ExceptionCenter_Detail failed midway through this script's apply —
   AFTER the rename-to-_OLD-and-drop step for Detail had already run.

   CONSEQUENCE: because the DROP-then-RENAME-then-CREATE sequence for each
   proc is itself three separate batches, the failed first attempt left
   sp_rpt_ExceptionCenter_Detail renamed away (to _OLD_20260928) with no
   replacement CREATE having succeeded yet, while Summary had already been
   fully replaced. All missing Detail blocks were then corrected against a
   freshly re-pulled, verified-correct OBJECT_DEFINITION (confirmed byte-for-
   byte via an automated diff before re-applying, not eyeballed) and this
   script was re-applied. Because the retry's own DROP-OLD-IF-EXISTS step
   found the _OLD_20260928 names already occupied by the FIRST attempt's
   artifacts, it deleted them before the second attempt's RENAME step could
   capture a genuine "immediately prior to this pass" snapshot — the net
   effect being sp_rpt_ExceptionCenter_Detail_OLD_20260928 ended up not
   existing at all, and sp_rpt_ExceptionCenter_Summary_OLD_20260928 ended up
   holding a snapshot IDENTICAL to the final live Summary (a redundant copy,
   not a true "before this pass" one) — confirmed live via
   OBJECT_DEFINITION() equality check.

   CORRECTION APPLIED (same pass): the true pre-pass bodies of both procs
   were still held in this pass's own captured OBJECT_DEFINITION() pulls
   (taken before any edit was made, per this file's header protocol note) and
   were used to recreate genuine historical snapshots:
     - dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260928 (the misleading
       redundant copy) was DROPPED.
     - dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260928_PREPASS was CREATED
       from the true pre-pass captured text (byte-identical to sections 2/3
       of THIS script with the SALES-CANCELLED-INVOICES block removed).
     - dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260928_PREPASS was likewise
       CREATED from the true pre-pass captured text.
   Re-verified after this correction: live sp_rpt_ExceptionCenter_Summary/
   _Detail unaffected and still return all 24 pre-existing checks with
   unchanged Findings/ValueAtRisk figures, plus the new
   SALES-CANCELLED-INVOICES check (5 / 0.00).
   LESSON, flagged for future passes on this shared proc pair: when a
   multi-batch DROP/RENAME/CREATE script fails partway and is retried, the
   retry's own "DROP _OLD IF EXISTS" step can destroy a snapshot the FIRST
   attempt already created before the SECOND attempt gets a chance to
   populate it with the genuine prior body — re-verify _OLD contents (not just
   existence) before trusting them as a rollback point after any failed-then-
   retried apply, not only before a fresh CREATE.
============================================================================ */


/* ============================================================================
   SMOKE TEST (run manually after apply; commented out so this script stays
   replayable without side effects if re-run)
============================================================================ */
/*
EXEC dbo.sp_rpt_ExceptionCenter_Summary @DateFrom = '2020-01-01', @DateTo = '2026-12-31';
-- Expect a SALES-CANCELLED-INVOICES row: Findings = 5, ValueAtRisk = 0.00 (see header quirk).

EXEC dbo.sp_rpt_ExceptionCenter_Detail
    @ExceptionCode = 'SALES-CANCELLED-INVOICES',
    @DateFrom = '2020-01-01', @DateTo = '2026-12-31';
-- Expect 5 rows, TotalMatchCount = 5, TotalAmount/Balance/AmountPaid all 0.00,
-- Remarks showing 'SERVICE CHARGE - <ref>' style text on at least some rows.
*/
