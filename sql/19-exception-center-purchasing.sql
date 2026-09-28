/* ============================================================================
   CORE REPORTING PORTAL — EXCEPTION CENTER (Build Order Step 4)
   Target: CORECSERP_002_DEV only (never staging without asking).

   Scope of THIS script: Purchasing category ONLY, per the brief's build
   order and the task's explicit boundary (Inventory + Master Data deferred
   to later passes). Segregation of Duties (sql/15), Vouchering + Post
   Expense (sql/16), AR (sql/17), and Sales (sql/18) are already shipped and
   are NOT touched here — this script only ADDS 4 new ExceptionDefinition
   rows and 4 new IF @ExceptionCode branches to the two existing shared
   procs, following the exact same pattern as all four prior passes.

   ----------------------------------------------------------------------------
   SCHEMA INVESTIGATION — CONFIRMED LIVE ON CORECSERP_002_DEV, NOT ASSUMED
   ----------------------------------------------------------------------------
   The brief's premise names generic "PO"/"receiving" tables. This schema has
   THREE unrelated table families that all look plausible from their names
   alone; only one of them is the genuine supplier purchase-order workflow.
   Each was checked against live data before being ruled in or out:

   1. dbo.PurchaseOrderSummary / dbo.PurchaseOrderDetails — RULED OUT. Despite
      the name, this is NOT a supplier PO. Its "Customer" column holds
      CUSTOMER keys (format 00000008, matching dbo.Customers.CustomerKey),
      its PONumber range (4687-7431 confirmed live) is the EXACT same PONumber
      series already documented in sql/18-exception-center-sales.sql as
      "DeliverySummary.PONumber IS the eventual customer PO number, bridged
      to TransactionChargeSales.ReferenceNo" — confirmed by cross-reference,
      not by name similarity alone. PurchaseOrderDetails even carries a
      SellingPrice column, which a supplier purchase order would never have.
      This is the CUSTOMER's purchase order (their order to us), i.e. Sales
      module territory already covered by sql/18's DeliverySummary checks —
      NOT touched again here.

   2. dbo.ReceiveOrderSummary / dbo.ReceivedOrderDetails — RULED OUT. No
      SupplierID column on either table (confirmed live via
      INFORMATION_SCHEMA.COLUMNS). PONumber range (3378-4499, confirmed live)
      is fully disjoint from both PurchaseOrderSummary's AND the genuine
      supplier-PO table's (below) numbering — a completely separate counter.
      ReceivedBy values observed live are branch-user logins (e.g.
      'branch004') and BranchCode spans outlying branches ('001'-'012'), never
      supplier-facing HQ activity. This is almost certainly the BRANCH-side
      receipt of HQ-to-branch STOCK TRANSFERS (a customer/branch order shipped
      from 888 and received at the branch) — Inventory-category territory
      ("stock transfers shipped but not yet received" / "received with
      quantity variance"), explicitly deferred per this task's scope
      boundary. Named here, not silently conflated with Purchasing.

   3. dbo.POSUMMARY (header) + dbo.PODETAILS (lines), joined on ShipmentNo —
      CONFIRMED, this is the real supplier purchase-order + receiving
      workflow, and the basis for every check below.
        dbo.POSUMMARY: ShipmentNo varchar(10) NOT NULL, BranchCode char(3)
          NOT NULL (genuine own BranchCode column — no indirect-resolution
          workaround needed, unlike CheckVoucher in sql/16), SupplierID
          varchar(30) NOT NULL, TargetDate date, TotalItems/TotalQty/TotalCost
          decimal, TotalActualQty/TotalActualCost decimal, Status varchar(20),
          OrderType char(1) (observed: always 'P' live), DateOrder datetime
          (REAL sub-day timestamps, confirmed live — unlike TicketMaster's
          date-only TicketDate), OrderedBy varchar(30), ApprovedDate datetime
          / ApprovedBy varchar(30), ReceivedDate datetime / ReceivedBy
          varchar(30), Remarks varchar(5000).
        dbo.PODETAILS: ShipmentNo varchar(10) NOT NULL (FK-shaped, not
          declared — confirmed live 0 orphan PODETAILS rows against
          POSUMMARY), SupplierID varchar(30) NOT NULL, OrderType char(1),
          OrderCode char(5) NOT NULL (a Products.ProductCode value, confirmed
          live), Quantity decimal(10,2) (ordered qty), Cost float, TotalCost
          float, Unit varchar(10) (observed: always 'kg' live — no UOM-
          conversion complication), ActualQuantity decimal(10,2) (received
          qty), ActualCost/ActualTotalCost decimal(18,2), isVat bit,
          ReferenceCode varchar(150) (a lot/batch reference, blank on most
          rows).
        dbo.Supplier (SupplierID, SupplierName) and dbo.Products (ProductCode
          + BranchCode composite, Description — confirmed unique per pair
          live) are joined for display, same pattern as prior scripts.

   ----------------------------------------------------------------------------
   PO STATUS LIFECYCLE — CONFIRMED AGAINST LIVE DATA, NOT ASSUMED (brief
   explicitly asked to verify "FOR CONFIRMATION" before deciding what it means)
   ----------------------------------------------------------------------------
   SELECT DISTINCT Status FROM POSUMMARY (confirmed live, 2026-09-23): exactly
   7 values exist — CANCELLED, CONFIRMED, DELIVERED, FOR APPROVAL, FOR
   CONFIRMATION, FOR DELIVERY, RECEIVED. Cross-tabulated every status against
   whether ApprovedDate/ReceivedDate are populated (non-sentinel; the sentinel
   observed is 1900-01-01, same convention as CheckVoucher-family "empty date"
   fields elsewhere in this schema) to reconstruct the REAL lifecycle instead
   of guessing from the English words:
     - FOR APPROVAL: ApprovedDate NOT populated, ReceivedDate NOT populated.
       The PO exists, awaiting approval. Confirmed live: 2 rows (ShipmentNo
       10989, 10991).
     - FOR DELIVERY: ApprovedDate IS populated (100% of 16 live rows),
       ReceivedDate NOT populated (100% of 16). Approved, not yet received —
       exactly the brief's Check #2 population. Confirmed live: 16 rows.
     - FOR CONFIRMATION: ReceivedDate IS ALREADY populated (100% of 2 live
       rows) even though the header hasn't flipped to CONFIRMED/RECEIVED yet.
       This is the brief's literal Check #3 status, CONFIRMED DISTINCT from
       FOR APPROVAL: it does NOT mean "awaiting order approval" — it means
       the goods have ALREADY been physically received and entered
       (ReceivedDate/ReceivedBy populated) but the receiving entry itself is
       awaiting a separate confirmation/verification step before the PO is
       finalized as CONFIRMED or RECEIVED. Confirmed live: 2 rows (ShipmentNo
       11005, 11011).
     - CONFIRMED / RECEIVED: both terminal states, both 100% ReceivedDate-
       populated (3 and 24 live rows respectively). No live evidence
       distinguishes them further (e.g. a downstream GL-posting flag) with
       today's data; treated as equally "done" for these checks, neither is
       flagged by anything below.
     - CANCELLED: 1 live row, ReceivedDate not populated (rejected before
       receipt, as expected). Not flagged by anything below.
     - DELIVERED: 320 live rows, ReceivedDate NOT populated on any of them —
       see "DELIVERED — MIGRATION ARTIFACT" note immediately below for why
       this status is EXCLUDED from Check #2 rather than treated as "approved,
       pending receipt".

   ----------------------------------------------------------------------------
   DELIVERED — MIGRATION ARTIFACT, DELIBERATELY EXCLUDED FROM CHECK #2
   ----------------------------------------------------------------------------
   All 320 DELIVERED rows share these traits, confirmed live: ShipmentNo
   00001-00320 (a distinct, much lower numbering block than the 10900s+ range
   every other live status uses), DateOrder AND ApprovedDate identical to the
   SECOND across all 320 rows (2026-09-07 10:08:47 AM — a single bulk-insert
   timestamp, not 320 independently-placed orders), BranchCode = '888' on
   100% of them, OrderedBy = ApprovedBy = 'merlyn borres' on every sampled
   row, and ReceivedDate/ReceivedBy never populated on any of them. This is a
   one-time historical data migration/backfill batch, not organic live PO
   activity — the English word "DELIVERED" evidently meant "closed/complete"
   in whatever system or process produced this batch, and the newer
   ReceivedDate/ReceivedBy columns were never backfilled for it. Treating
   these 320 rows as "approved, pending receipt" (Check #2) would flag every
   one of them as ~16+ days stale, drowning the 16 genuine FOR DELIVERY
   findings in migration noise and misrepresenting a one-time backfill as an
   active receiving backlog. Check #2 below is therefore scoped to
   Status = 'FOR DELIVERY' explicitly (not a NOT-IN exclusion list), so this
   artifact cannot leak in even if more legacy statuses surface later. Flagged
   here as a data-quality item for the developer: either backfill
   ReceivedDate on this migrated batch, or accept it will never appear in any
   receiving-completeness check as currently scoped.

   ----------------------------------------------------------------------------
   COST DATA-QUALITY FINDING — READ BEFORE TRUSTING ANY PESO FIGURE BELOW
   ----------------------------------------------------------------------------
   Confirmed live: PODETAILS.Cost = 0 on ALL 52 live rows (100%), and
   POSUMMARY.TotalCost = 0 on ALL 48 non-DELIVERED rows (100% of the live/
   organic subset; the 320 DELIVERED migration rows DO carry a nonzero
   TotalCost, consistent with them being backfilled from an older system that
   captured cost differently). Cross-checked against dbo.APACCOUNTS
   (ActualCost) for the same recent ShipmentNos — also 0.00 on every row
   checked. CONCLUSION: this ERP's live purchasing workflow does not capture
   supplier cost at PO-entry time in current DEV data (likely entered later,
   at AP-invoice time, via a different table not yet wired back to
   PODETAILS/APACCOUNTS in this test data). This means every ValueAtRisk
   figure below computes to $0.00 against today's live data — NOT because the
   SQL is wrong, but because the source column it correctly reads is
   genuinely zero everywhere live. The detection LOGIC (which POs/lines get
   flagged, by count and by quantity) is fully real and already finds genuine
   findings (see smoke test) — only the peso valuation is currently
   unmeasurable. This is the single biggest data-quality gap found in this
   pass and should be flagged to the developer separately: PODETAILS.Cost
   should be populated at PO-entry (even if provisional/estimated) for these
   checks' ValueAtRisk to mean anything in production.

   ----------------------------------------------------------------------------
   POSTED-ONLY / GL RULE — DOES NOT APPLY HERE, DOCUMENTED PER CLAUDE.MD
   ----------------------------------------------------------------------------
   POSUMMARY/PODETAILS are NOT general-ledger-posted tables — there is no
   Status IN ('POSTED','UPDATED') concept here at all; the table's own Status
   column (FOR APPROVAL / FOR DELIVERY / etc.) IS the governing
   posting/confirmation concept for this domain, used directly. Same pattern
   already established for DeliverySummary in sql/18 — named explicitly here
   rather than silently applying an inapplicable rule.

   ----------------------------------------------------------------------------
   CHECK #5 — "RECEIVING POSTED WITH NO PO REFERENCE" — NOT BUILDABLE,
   STRUCTURALLY IMPOSSIBLE IN THIS SCHEMA, NOT SILENTLY SKIPPED
   ----------------------------------------------------------------------------
   Confirmed live: PODETAILS.ShipmentNo is NOT NULL, and every PODETAILS row
   ties back to a POSUMMARY row (0 orphans, confirmed above). There is NO
   separate "receiving" table in this workflow — receiving IS an update to
   the PO's own line (ActualQuantity/ActualCost on PODETAILS) and header
   (ReceivedDate/ReceivedBy on POSUMMARY). A receiving event literally cannot
   exist without a PO line to attach the received quantity to, because the
   received-quantity COLUMN lives ON the PO line itself. There is no
   independent receiving record with its own nullable PO-reference field to
   check for a missing/blank value. This is a genuine structural
   impossibility, not a data-quality gap that happens to show zero rows —
   there is no query that could ever find a match here, so none is written.
   NOT BUILT, no ExceptionDefinition row seeded for it, per the after-hours-
   postings precedent (sql/15) and the "high edit rate" precedent (sql/16):
   name it, don't force a check that will always show zero and call it done.
   RELATED FINDING, named but explicitly OUT OF SCOPE for this Purchasing
   pass: dbo.Inventory (the general on-hand stock ledger, fed by many sources
   — POs, transfers, adjustments, butchery/conversion output) DOES have a
   nullable ShipmentNo, and 32 of 7,829 live rows (confirmed live) have a
   blank ShipmentNo with a distinct ReferenceCode pattern ('INVIN-###') and
   isSource=1/isConversion=0/isProcess=1 flags — this looks like a genuine,
   separate "manual inventory-in" entry mechanism, NOT a PO-driven receiving
   event without a PO. Investigating whether THAT specific manual-entry path
   needs its own exception check is Inventory-category work, explicitly
   deferred per this task's scope boundary — flagged here for whoever builds
   that category next, not built now.

   ----------------------------------------------------------------------------
   BRANCHCODE HANDLING
   ----------------------------------------------------------------------------
   POSUMMARY carries its own genuine BranchCode column (char(3) NOT NULL) —
   no indirect resolution via a payment-details table is needed here (unlike
   CheckVoucher in sql/16, which has no BranchCode of its own at all).
   PODETAILS has no BranchCode of its own; Check #4 (line-level) joins back to
   POSUMMARY for it. Always treated/cast as varchar per Hard Rule #2, never
   converted to int.

   ----------------------------------------------------------------------------
   AGING PLACEHOLDERS — NOT the developer's real house numbers, same
   treatment as every prior placeholder in this module (sql/16 @StaleDays,
   sql/17 @CreditBalanceStaleDays, sql/18 @UnconfirmedOrderHours)
   ----------------------------------------------------------------------------
   @PendingApprovalDays = 2: rationale — this ERP's own observed live cadence
   from order-to-approval is MINUTES for every fast-moving PO (see the joined
   POSUMMARY+PODETAILS timestamps sampled live: most ShipmentNos move from
   DateOrder to ApprovedDate within seconds to a few minutes), so a PO still
   awaiting approval after 2 full days is already a significant outlier by
   this system's own demonstrated pace, not an arbitrarily tight number.
   Confirmed live real findings at this threshold: ShipmentNo 10989 (7 days
   pending) and 10991 (5 days pending) — both genuine, not hypothetical.
   @ApprovedPendingReceiptDays = 3: rationale — same logic; approved POs in
   this data move to RECEIVED same-day in the overwhelming majority of
   sampled cases, so 3 days is a generous placeholder before flagging a
   delivery delay, not a tight one. Confirmed live: all 16 current FOR
   DELIVERY rows already exceed this (minimum age 4 days as of 2026-09-23),
   a genuine finding, not a threshold picked to force a hit.
   REVISIT both with the developer's actual procurement SLA before treating
   either as authoritative.

   ----------------------------------------------------------------------------
   SEVERITY DECISIONS (documented per developer's ask to justify each)
   ----------------------------------------------------------------------------
   - PUR-PENDING-APPROVAL: Warning. An approval backlog is an operational
     bottleneck (procurement/supply-chain risk if it delays inbound stock),
     not evidence of fraud or a control override by itself.
   - PUR-APPROVED-PENDING-RECEIPT: Warning, same reasoning — a logistics/
     delivery-delay signal, not a control failure.
   - PUR-FOR-CONFIRMATION: Warning. Goods have already physically arrived
     (ReceivedDate populated) but the confirmation/verification step that
     finalizes the transaction hasn't happened — worth a timely follow-up
     (an un-confirmed receipt can hide a quantity/cost discrepancy that
     hasn't been reconciled yet), but it is a pending administrative step,
     not by itself proof of an error or override.
   - PUR-OVER-RECEIPT: Critical. Unlike VOU-CANCELLED-CHECKS/VOU-REVERSED-
     VOUCHERS (which reuse an AUDITED control action with a captured
     reason), there is no corresponding authorization step captured anywhere
     in this schema for accepting MORE than what was ordered — ActualQuantity
     is simply overwritten past Quantity with no separate approval, reason
     code, or audit trail for the excess. That is either a genuine supplier
     over-shipment accepted without a control gate, a data-entry error
     inflating recorded stock (and therefore inventory value and COGS
     downstream), or a diversion-risk pattern — all three warrant the same
     urgency as VOU-DUP-CHECKNO's reasoning (structural risk, no audited
     control that explains it away). Confirmed live: 1 genuine finding
     (ShipmentNo 11013, OrderCode 13565, ordered 10,000 kg vs received
     14,998.22 kg — a 50% quantity variance on a status='RECEIVED' order).

   ----------------------------------------------------------------------------
   DB CHANGE PROTOCOL
   ----------------------------------------------------------------------------
   The two shared procs already exist in DEV (built in sql/15, extended in
   sql/16 [_OLD_20260923B/C], sql/17 [_OLD_20260923D], sql/18
   [_OLD_20260923E]). Confirmed live via sys.procedures before writing this
   script: the current, unsuffixed sp_rpt_ExceptionCenter_Summary/_Detail are
   the sql/18 versions; _OLD_20260923E is the latest suffix taken. Per
   CLAUDE.md / db-change-protocol, this pass preserves the current
   definitions under _OLD_20260923F (next available letter) rather than
   dropping them, so every prior version remains queryable.
============================================================================ */


/* ============================================================================
   1. dbo.ExceptionDefinition — seed the 4 new PURCHASING checks from this
   pass (PUR-RECEIVING-NO-PO-REF deliberately NOT seeded — structurally
   impossible, see header). No DDL change to the table itself.
============================================================================ */
MERGE dbo.ExceptionDefinition AS tgt
USING (VALUES
    ('PUR-PENDING-APPROVAL',        'Purchasing', 'Purchase orders pending approval, aged by days',
     'Warning',  1, '/ExceptionCenter/Detail?code=PUR-PENDING-APPROVAL', 60),
    ('PUR-APPROVED-PENDING-RECEIPT','Purchasing', 'Approved purchase orders pending receipt, aged by days',
     'Warning',  1, '/ExceptionCenter/Detail?code=PUR-APPROVED-PENDING-RECEIPT', 61),
    ('PUR-FOR-CONFIRMATION',        'Purchasing', 'Purchase orders received, awaiting confirmation',
     'Warning',  1, '/ExceptionCenter/Detail?code=PUR-FOR-CONFIRMATION', 62),
    ('PUR-OVER-RECEIPT',            'Purchasing', 'Received quantity exceeds ordered quantity on a PO line',
     'Critical', 1, '/ExceptionCenter/Detail?code=PUR-OVER-RECEIPT', 63)
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
   2. dbo.sp_rpt_ExceptionCenter_Summary — add 4 new INSERT blocks
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923F', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923F;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Summary', 'sp_rpt_ExceptionCenter_Summary_OLD_20260923F';
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

    /* ---- SALES-CREDIT-LIMIT-BREACH: unchanged from sql/18 ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'SALES-CREDIT-LIMIT-BREACH',
        COUNT(*),
        SUM(b.TotalAmount)
    FROM (
        SELECT
            ds.DeliveryNo, ds.DateAdded, tcs.CustomerKey, tcs.TotalAmount,
            PriorBalance = (
                SELECT TOP (1) cl.EndingBalance
                FROM dbo.ClientLedger AS cl
                WHERE cl.AccountKey = tcs.CustomerKey
                  AND cl.TransactionDate < ds.DateAdded
                ORDER BY cl.TransactionDate DESC, cl.TRN_SEQ_NO DESC
            )
        FROM dbo.DeliverySummary AS ds
        JOIN dbo.TransactionChargeSales AS tcs ON tcs.ReferenceNo = ds.PONumber
        WHERE ds.Status IN ('DELIVERED','RETURNED')
          AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
    ) AS b
    JOIN dbo.Customers AS c ON c.CustomerKey = b.CustomerKey
    WHERE ISNULL(b.PriorBalance, 0) + b.TotalAmount > ISNULL(c.CustomerCreditLimit, 0);

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


/* ============================================================================
   3. dbo.sp_rpt_ExceptionCenter_Detail — add 4 new IF @ExceptionCode branches
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923F', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923F;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Detail', 'sp_rpt_ExceptionCenter_Detail_OLD_20260923F';
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

    /* ==== SALES-CREDIT-LIMIT-BREACH — unchanged from sql/18 ==== */
    IF @ExceptionCode = 'SALES-CREDIT-LIMIT-BREACH'
    BEGIN
        ;WITH Orders AS (
            SELECT
                ds.DeliveryNo, ds.PONumber, ds.Status, ds.DateAdded, tcs.CustomerKey, tcs.TotalAmount,
                PriorBalance = (
                    SELECT TOP (1) cl.EndingBalance
                    FROM dbo.ClientLedger AS cl
                    WHERE cl.AccountKey = tcs.CustomerKey
                      AND cl.TransactionDate < ds.DateAdded
                    ORDER BY cl.TransactionDate DESC, cl.TRN_SEQ_NO DESC
                )
            FROM dbo.DeliverySummary AS ds
            JOIN dbo.TransactionChargeSales AS tcs ON tcs.ReferenceNo = ds.PONumber
            WHERE ds.Status IN ('DELIVERED','RETURNED')
              AND ds.DateAdded >= @DateFrom AND ds.DateAdded < CAST(@End AS date)
        )
        SELECT TOP (500)
            DeliveryNo        = CAST(o.DeliveryNo AS varchar(20)),
            PONumber          = CAST(o.PONumber AS varchar(20)),
            Status            = CAST(o.Status AS varchar(50)),
            DateAdded         = CAST(o.DateAdded AS date),
            CustomerKey       = CAST(o.CustomerKey AS char(8)),
            CustomerName      = CAST(ISNULL(c.CustomerName, '') AS varchar(200)),
            PriorBalance      = CAST(ISNULL(o.PriorBalance, 0) AS decimal(18,2)),
            OrderAmount       = CAST(o.TotalAmount AS decimal(18,2)),
            BalanceAfterOrder = CAST(ISNULL(o.PriorBalance, 0) + o.TotalAmount AS decimal(18,2)),
            CreditLimit       = CAST(c.CustomerCreditLimit AS decimal(18,2)),
            ExcessOverLimit   = CAST((ISNULL(o.PriorBalance, 0) + o.TotalAmount) - c.CustomerCreditLimit AS decimal(18,2))
        FROM Orders AS o
        JOIN dbo.Customers AS c ON c.CustomerKey = o.CustomerKey
        WHERE ISNULL(o.PriorBalance, 0) + o.TotalAmount > ISNULL(c.CustomerCreditLimit, 0)
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
   SMOKE TEST
============================================================================ */
/*
DECLARE @From date = '2020-01-01', @To date = '2026-12-31';

EXEC dbo.sp_rpt_ExceptionCenter_Summary @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect (verified live against DEV on 2026-09-23) — 15 PRE-EXISTING checks
-- unaffected by this pass, plus 4 NEW Purchasing checks:
--   SOD-SAME-PREP-APPR              Findings=1    ValueAtRisk=3688581595.84
--   VOU-CANCELLED-CHECKS            Findings=3    ValueAtRisk=334550.59
--   VOU-REVERSED-VOUCHERS           Findings=4    ValueAtRisk=349550.59
--   VOU-DUP-CHECKNO                 Findings=7    ValueAtRisk=583184.37
--   VOU-DUP-SUPPLIER-INVOICE        Findings=2    ValueAtRisk=1062922.85
--   VOU-STALE-OUTSTANDING-CHECKS    Findings=1    ValueAtRisk=26153.50
--   EXP-REVERSALS                   Findings=4    ValueAtRisk=349550.59
--   AR-REVERSED-PAYMENTS            Findings=1    ValueAtRisk=9049.60
--   AR-STALE-CREDIT-BALANCE         Findings=169  ValueAtRisk=2039671.87
--   SALES-UNCONFIRMED-ORDERS        Findings=45   ValueAtRisk=0.00
--   SALES-VATABLE-ZERO-VAT          Findings=75   ValueAtRisk=114000.00
--   SALES-CM-CLIENT                 Findings=26   ValueAtRisk=1476101.10
--   SALES-RETURNED-ORDERS           Findings=96   ValueAtRisk=3405042.08
--   SALES-CREDIT-LIMIT-BREACH       Findings=860  ValueAtRisk=32444001.87
--   SALES-BELOW-COST                Findings=577  ValueAtRisk=727486.86
--   PUR-PENDING-APPROVAL            Findings=2    ValueAtRisk=0.00   (NEW —
--                                       ShipmentNo 10989 [7 days pending],
--                                       10991 [5 days pending], both > the
--                                       2-day placeholder; $0 ValueAtRisk is
--                                       correct/honest, see header "COST
--                                       DATA-QUALITY FINDING", not a bug)
--   PUR-APPROVED-PENDING-RECEIPT    Findings=16   ValueAtRisk=0.00   (NEW —
--                                       all 16 live 'FOR DELIVERY' rows,
--                                       ages 4-19 days, all > the 3-day
--                                       placeholder; the 320-row DELIVERED
--                                       migration batch correctly does NOT
--                                       appear here, see header)
--   PUR-FOR-CONFIRMATION            Findings=2    ValueAtRisk=0.00   (NEW —
--                                       ShipmentNo 11005, 11011)
--   PUR-OVER-RECEIPT                Findings=1    ValueAtRisk=0.00   (NEW —
--                                       ShipmentNo 11013 / OrderCode 13565,
--                                       ordered 10,000 kg vs received
--                                       14,998.22 kg, a real 49.98% quantity
--                                       variance; $0 ValueAtRisk is correct/
--                                       honest per the same cost gap)

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'PUR-PENDING-APPROVAL', @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect exactly 2 rows: ShipmentNo 10989 (DaysPending=7, SupplierID 000007,
-- BranchCode 003) and 10991 (DaysPending=5, SupplierID 000014, BranchCode 888).

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'PUR-APPROVED-PENDING-RECEIPT', @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect exactly 16 rows, DaysSinceApproval ranging 4 (ShipmentNo 10995) to
-- 19 (the 12 ShipmentNos from 2026-09-04, BranchCode 001).

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'PUR-FOR-CONFIRMATION', @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect exactly 2 rows: ShipmentNo 11005 (DaysAwaitingConfirmation=1) and
-- 11011 (DaysAwaitingConfirmation=0).

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'PUR-OVER-RECEIPT', @DateFrom = @From, @DateTo = @To;
-- Expect exactly 1 row: ShipmentNo 11013, ProductCode 13565 (PORK SHOULDER
-- BONELESS SKINLESS), OrderedQty=10000.000, ReceivedQty=14998.220,
-- VarianceQty=4998.220, VariancePct=49.98.

-- Point-in-time regression check: rerun PUR-PENDING-APPROVAL as of a date
-- BEFORE ShipmentNo 10991 crossed the 2-day threshold (DateOrder
-- 2026-09-18 13:42:13 + 2 days = 2026-09-20) and confirm it drops out:
EXEC dbo.sp_rpt_ExceptionCenter_Summary @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-19';
-- Expect PUR-PENDING-APPROVAL Findings=1 (only 10989 qualifies; DATEDIFF(DAY,
-- '2026-09-18 13:42:13','2026-09-19')=1, not > 2).

-- Fails loudly, does not silently return empty:
-- EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'NOT-A-REAL-CODE', @DateFrom = @From, @DateTo = @To;
*/
