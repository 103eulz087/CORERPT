/* ============================================================================
   CORE REPORTING PORTAL — EXCEPTION CENTER (Build Order Step 2, completing it)
   Target: CORECSERP_002_DEV only (never staging without asking).

   Scope of THIS script: the AR category ONLY, per the brief's build order —
   Segregation of Duties (sql/15-exception-center.sql) and Vouchering + Post
   Expense (sql/16-exception-center-vouchering-postexpense.sql) are already
   shipped and reviewed and are NOT touched here. This script only ADDS two new
   ExceptionDefinition rows and two new IF @ExceptionCode branches to the two
   existing shared procs, following the exact same pattern as both prior passes.

   ----------------------------------------------------------------------------
   CHECK 1 — AR-REVERSED-PAYMENTS: SCHEMA INVESTIGATION (live, not assumed)
   ----------------------------------------------------------------------------
   dbo.sp_ReversePaymentClient (OBJECT_ID confirmed to exist; also found 3 dated
   snapshot copies — sp_ReversePaymentClient_06262026-2154,
   _06272026, _07112026 — confirming this proc really was iterated on
   extensively in June/July as the brief claimed). READ via OBJECT_DEFINITION
   before writing anything. Conclusion: this is a WRITE proc (BEGIN TRAN /
   COMMIT, XACT_ABORT ON) — it updates TransactionChargeSales (AmountPaid/
   EWTAmount/DiscountAmount/OffsetAmount/Balance/PayStatus), ARPaymentDetails
   (sets ErrorTag=1 on the reversed legs), inserts a REVERSAL TicketMaster +
   TicketDetails pair (swapped Debit/Credit) via GetTicketNumber, inserts
   reversing ClientLedger rows, updates PaymentHeader (Status='REVERSED',
   ReversedBy, ReversedDate), flags TransactionCashCollection.isErrorCorrect=1
   / TransactionCheque.Remarks='REVERSED' / TransactionOnline.Remarks=
   'REVERSED', and resolves the matching BankStatementRecon DIT row. Per
   CLAUDE.md Hard Rule #9 / db-change-protocol, a reporting proc NEVER calls a
   write proc like this — same pattern already established for
   sp_CancelledChequesCS in sql/16. This proc's WRITE SIDE EFFECTS land in
   plain tables a read-only report can SELECT from directly.

   CRITICAL FINDING, checked live, not assumed: dbo.PaymentReversalAudit —
   the table this brief's premise assumed would carry the AR trail under "some
   other VoucherType value" — does NOT. Ran `SELECT DISTINCT VoucherType FROM
   PaymentReversalAudit` live: only 'EXPENSE' exists today (0 'PURCHASE' rows
   too, matching sql/16's own observation that all 4 rows there are EXPENSE).
   Read sp_ReversePaymentClient's full body top to bottom: it NEVER inserts
   into PaymentReversalAudit at all — that table is written exclusively by the
   AP-side cancel/reversal procs (sp_CancelledChequesCS and its expense-flow
   siblings), not by the AR client-payment reversal path. Searched
   sys.objects for '%Client%Payment%' / '%Payment%Client%' / '%Revers%' names
   too (see full result list below) — no dedicated "ClientPaymentReversalAudit"
   or similar table exists anywhere in the schema.

   The REAL trail — confirmed live against the one existing reversed row
   (PaymentHeaderID 4264) — is dbo.PaymentHeader itself:
     dbo.PaymentHeader: PaymentHeaderID int PK, CustomerKey char(8) NULLable,
       ReferenceNo varchar(20), ControlNo varchar(30), CRNo varchar(20),
       PaymentType varchar(30) (observed: 'CASH'|'CHECK' only, 40/3 split —
       this is the PAYMENT INSTRUMENT, unrelated to CheckVoucher's own
       VoucherType='CHECK'-always quirk from sql/16), TotalAmount decimal,
       PaymentDate date, Remarks varchar(500) (free-text, always blank on the
       one live reversed row — there is NO dedicated CancelReason/
       ReversalReason column on this table, unlike CheckVoucher.CancelReason
       on the AP side; see data-quality note below), CreatedBy varchar(50),
       CreatedDate datetime, Status varchar(20) (observed: 'POSTED'|
       'REVERSED', 42 vs 1 of 43 rows today), IsValidated bit, ReversedBy
       varchar(50), ReversedDate datetime. Status/ReversedBy/ReversedDate are
       the exact three-column reversal signature this check needs, populated
       together and only together by sp_ReversePaymentClient's step 10 UPDATE
       — confirmed live: the one Status='REVERSED' row has both ReversedBy
       ('juvie') and ReversedDate (2026-09-10 20:20:57) populated, non-NULL.
   This check therefore reads dbo.PaymentHeader directly, exactly the same
   "write proc's side effects land in a plain table, read that table" pattern
   used for CheckVoucher/PaymentReversalAudit in sql/16 — no cross-table proof
   was needed here since PaymentHeader alone carries the full reversal
   signature (unlike the AP side, which needed PaymentReversalAudit because
   CashVoucher has nowhere on itself to record cancellation detail).

   NO BranchCode column exists on PaymentHeader (confirmed via
   INFORMATION_SCHEMA — 0 columns LIKE '%Branch%'), matching the same
   no-branch-dimension gap already flagged for CheckVoucher in sql/16. Branch
   is attributed via Customers.BranchCode (the customer's HOME branch) joined
   on PaymentHeader.CustomerKey = Customers.CustomerKey — the SAME convention
   already established in sql/05-accounting-aging.sql for AR aging (never
   TransactionChargeSales.BranchCode, which is the invoice's SELLING branch —
   a different, unrelated dimension per this brief's own instruction). LEFT
   JOINed, never dropped, matching the "never silently drop unattributable
   rows" precedent from sql/05: confirmed live, 0 of 0 reversed-row CustomerKey
   values fail to match Customers (PaymentHeaderID 4264 -> CustomerKey
   '00005571' -> Customers.BranchCode = '005'), so this gap is currently
   theoretical for AR but handled identically to the AP case regardless.

   GROSS-VS-NET CHECK (Hard Rule #8 discipline) — confirmed live before
   trusting PaymentHeader.TotalAmount as this check's ValueAtRisk source:
   reconciled TotalAmount against SUM(ARPaymentDetails.Amount) per header
   across all 43 PaymentHeader rows. 5 of 43 disagree (e.g. PaymentHeaderID
   4267: TotalAmount=37,125.00 vs SUM(Amount)=37,875.00, a 750.00 gap) —
   traced to EWT legs: ARPaymentDetails stores EWT as its own positive-Amount
   row (375.00 example: 4267's EWT leg), so naively summing ALL legs
   double-counts the withholding instead of netting it, while
   PaymentHeader.TotalAmount is already the correct net-cash-received figure
   (37,500 INVOICE PAYMENT - 375 EWT = 37,125, matching TotalAmount exactly).
   This is the exact "AP debit booked net of withholding" family of bug
   CLAUDE.md calls out, mirrored on the AR side — using PaymentHeader.
   TotalAmount directly (never re-deriving it by summing ARPaymentDetails
   legs) avoids it entirely. Confirmed the ONE currently-reversed row
   (PaymentHeaderID 4264) has NO such gap (TotalAmount=9,049.60 = 8,179.20
   INVOICE PAYMENT + 870.40 OVERPAY exactly, no EWT leg on that header), so
   today's single finding is unaffected either way — but the general rule
   (always TotalAmount, never SUM(ARPaymentDetails.Amount)) is what's used
   below, and is the reason this check does NOT join to ARPaymentDetails at
   all for its ValueAtRisk.

   Windowed on ReversedDate (when the reversal happened), matching
   VOU-REVERSED-VOUCHERS' windowing on CancelledDate rather than the original
   PaymentDate — consistent with "the exception is the reversal event, not the
   original transaction" already established in sql/16.

   ----------------------------------------------------------------------------
   CHECK 1 SEVERITY DECISION — Warning
   ----------------------------------------------------------------------------
   Same reasoning as VOU-REVERSED-VOUCHERS / EXP-REVERSALS in sql/16:
   sp_ReversePaymentClient requires an explicit @ReversedBy, populates
   ReversedBy + ReversedDate together as an audited control action, and
   additionally leaves a full downstream trail (a REVERSED-status TicketMaster
   header + reversing TicketDetails, reversing ClientLedger rows, ErrorTag=1
   on the reversed ARPaymentDetails legs) — confirmed live end-to-end for
   PaymentHeaderID 4264 / ReferenceNo 14107 (TicketMaster TicketNumber 5185
   'OR-OVERPAY ENTRY' + reversal TicketNumber 5194 'REVERSAL: OR-OVERPAY
   ENTRY', both ReferenceNumber='14107', reversal ticket dated exactly at
   ReversedDate). This is a working, audited correction mechanism, not an
   absence of control — worth monitoring for volume/pattern (repeat reversals
   by the same user, or reversals clustering around period-end), not an
   automatic red alert. Not Critical.

   DATA-QUALITY NOTE: PaymentHeader has no dedicated reversal-reason column
   (unlike CheckVoucher.CancelReason on the AP side) — Remarks is free-text
   and blank on the one live example. The detail drilldown surfaces Remarks
   as-is (never guessing at a reason), and this gap is flagged here for the
   developer the same way the after-hours and CheckVoucher-branch gaps were
   flagged in sql/15 and sql/16 — not fixed by this reporting pass.

   ----------------------------------------------------------------------------
   CHECK 2 — AR-STALE-CREDIT-BALANCE: NOT A RE-DERIVATION OF HEALTH CHECK
   SEQ 14 — READ THIS BEFORE TOUCHING EITHER CHECK
   ----------------------------------------------------------------------------
   dbo.sp_rpt_DataHealthCheck Seq 14 ("AR items with negative Balance",
   CRITICAL — sql/05-accounting-aging.sql lines 574-579) is:
       SELECT 14, 'AR items with negative Balance', 'CRITICAL',
              COUNT(*), SUM(ABS(Balance))
       FROM dbo.TransactionChargeSales
       WHERE Balance < 0;
   Confirmed live against CORECSERP_002_DEV today (2026-09-23): this returns
   Findings=205, ValueAtRisk=2,079,610.34. This check (AR-STALE-CREDIT-
   BALANCE) uses the EXACT SAME source table and the EXACT SAME sign filter
   (Balance < 0) — deliberately NOT re-deriving a different definition of
   "credit balance" that could quietly disagree with Health Check's own
   number. See the reconciliation note below for how the two numbers relate.

   sp_rpt_AR_Aging (same file, line 151 / line 239) explicitly filters its
   open-items source to `Balance > 0`, so every one of these 205 rows is
   already invisible to the AR Aging dashboard today — confirmed by
   construction (Balance < 0 and Balance > 0 are disjoint), not re-queried.

   WHAT THIS CHECK ADDS THAT NEITHER OF THOSE DOES — THE AGING DIMENSION:
   neither Health Check (a lump count+value assertion) nor AR Aging (which
   excludes these rows outright) shows WHICH customers, how large individually,
   or — the genuinely new question — HOW LONG each row has been sitting open.
   Confirmed live this is not a cosmetic distinction: of the 205 negative-
   balance rows, TransactionDate ranges from 2014-07-03 to 2026-07-31; the
   single largest row (CustomerKey 00001802, InvoiceNo 'C-000900',
   TransactionDate 2019-05-30, Balance -1,146,104.62) is over 7 years old and
   alone accounts for 55% of the total value-at-risk. A lump "205 rows,
   ₱2.08M" tile does not surface that concentration or that age — this check
   does, which is the actual business question the brief asked for, not a
   repeat of Health Check's own existence-assertion.

   RECONCILIATION — WHY THIS CHECK'S OWN Findings/ValueAtRisk NUMBERS ARE A
   SUBSET OF HEALTH CHECK SEQ 14'S, ON PURPOSE, NOT A DISAGREEMENT:
   Health Check Seq 14 has NO date window at all (a standing, all-time
   assertion: "this should never be true, count how often it currently is").
   This check's WHERE clause matches it exactly for population membership
   (`Balance < 0`, no @DateFrom/@DateTo filter on TransactionDate — see
   below), then ADDS an aging filter on top (`DATEDIFF(DAY, TransactionDate,
   @StaleAsOf) > @CreditBalanceStaleDays`) to select only the STALE subset —
   the rows old enough to be a genuine "why is this still open" exception
   rather than a same-week/same-month timing artifact. So:
     - The FULL population this check reads from (Balance < 0, no aging
       filter) is IDENTICAL to Health Check Seq 14's population by
       construction (same table, same sign filter) — confirmed live, both
       return 205 rows / 2,079,610.34 today.
     - This check's OWN reported Findings/ValueAtRisk (what appears on the
       Exception Center card) is the AGED SUBSET of that population: 169 rows
       / 2,039,671.87 as of @StaleAsOf='2026-09-23' with the 90-day threshold
       below — i.e. 82% of rows / 98% of value are already stale enough to
       flag. The 36 rows / 39,938.47 excluded are all very recent (2026-06-26
       to 2026-07-31 as of today), inside the aging window, and correctly NOT
       flagged as "stale" yet even though they already trip Health Check's
       existence assertion.
   A future reader comparing this card's number to Health Check's tile and
   seeing 169 vs 205 should read THIS note, not assume a bug — it is the
   aging filter doing exactly its documented job.

   @DateFrom/@DateTo ARE DELIBERATELY NOT USED TO FILTER THIS CHECK'S
   POPULATION (accepted for interface consistency with every other
   Exception Center check, but intentionally inert here beyond feeding the
   @StaleAsOf default) — mirroring the already-established precedent in
   sql/05 where sp_rpt_AR_Aging's DSO calculation deliberately ignores
   @BranchCodes for the same reason (a parameter that would silently break a
   tie-out is worse than an unused one, and both are explicitly documented
   rather than silently applied). Filtering TransactionDate by @DateFrom/
   @DateTo here would mean a caller picking a narrow reporting period sees a
   DIFFERENT, smaller population than Health Check Seq 14's own always-global
   number — breaking the very tie-out this check exists to reconcile against.
   Only @AsOfDate (defaulting to @DateTo, reusing the exact @StaleAsOf
   variable sql/16 already declared for VOU-STALE-OUTSTANDING-CHECKS — same
   "point-in-time aging reference, never hardcoded GETDATE()" concept, one
   variable, two consumers) drives this check's output.

   N-DAYS PLACEHOLDER (documented as a placeholder, same treatment as
   VOU-STALE-OUTSTANDING-CHECKS' @StaleDays=30 in sql/16 — NOT the developer's
   real house number)
   ----------------------------------------------------------------------------
   @CreditBalanceStaleDays = 90 is used below, kept in its own variable
   (distinct from sql/16's unrelated @StaleDays=30 for bank-check clearing —
   different domain, no reason the two thresholds should move together).
   Rationale for picking 90 as a starting placeholder: it matches the oldest
   bucket boundary sp_rpt_AR_Aging already uses for overdue receivables
   (PastDue90Plus, sql/05) — reusing an already-established boundary in the
   SAME accounting module gives a customer's credit balance and their overdue
   balance a symmetric "past 90 days = seriously aged" vocabulary instead of
   inventing an unrelated new number. Confirmed live this is a real,
   materially large finding at 90 days (169/205 rows, ₱2.04M), not a
   hypothetical one. REVISIT with the developer's actual write-off / refund
   policy before treating 90 as authoritative — exactly the same caveat sql/16
   attaches to its own placeholder.

   ----------------------------------------------------------------------------
   CHECK 2 SEVERITY DECISION — Critical
   ----------------------------------------------------------------------------
   Unlike every Warning-severity check in sql/16 (cancelled checks, reversed
   vouchers), there is NO audited control action behind a stale credit
   balance — nobody signed off on it sitting open; it is simply unresolved.
   Three factors together push this to Critical rather than Warning:
     (a) it inherits its severity signal from the fact that its own source
         condition (Balance < 0 on an AR subledger row) is ALREADY classified
         CRITICAL by sp_rpt_DataHealthCheck Seq 14 — this check does not
         invent a new severity judgment, it makes an already-Critical
         standing assertion actionable/triageable by age;
     (b) materiality: 98% of the total value-at-risk (2,039,671.87 of
         2,079,610.34) is concentrated in the stale bucket, and a SINGLE row
         is over half the total book value — this is not noise;
     (c) multi-year aging (oldest confirmed row: 2014-07-03, eleven years old
         as of today) indicates several of these were never reconciled, not
         merely slow-processing — a pattern more consistent with abandoned/
         forgotten subledger entries than routine timing lag.
   PayStatus is 'UNPAID' on every single one of these 205 rows despite a
   NEGATIVE Balance — confirmed live (0 rows with any other PayStatus value)
   — meaning this system's PayStatus field does not reflect the credit-balance
   state at all. Flagged here as an additional data-quality observation (not
   fixed): a downstream consumer must not trust PayStatus to identify these
   rows, only the Balance sign, which is exactly what both this check and
   Health Check Seq 14 already do.

   ----------------------------------------------------------------------------
   DB change protocol: the two shared procs already exist in DEV (built in
   sql/15, revised in sql/16 under _OLD_20260923 / _OLD_20260923B /
   _OLD_20260923C). Per CLAUDE.md / db-change-protocol, the current
   definitions are preserved under _OLD_20260923D rather than dropped, so all
   prior versions remain queryable.
============================================================================ */


/* ============================================================================
   1. dbo.ExceptionDefinition — seed the 2 new AR checks from this pass
   No DDL change to the table itself.
============================================================================ */
MERGE dbo.ExceptionDefinition AS tgt
USING (VALUES
    ('AR-REVERSED-PAYMENTS',    'AR', 'Reversed client (AR) payments',
     'Warning',  1, '/ExceptionCenter/Detail?code=AR-REVERSED-PAYMENTS', 40),
    ('AR-STALE-CREDIT-BALANCE', 'AR', 'Unapplied credit balances open beyond N days',
     'Critical', 1, '/ExceptionCenter/Detail?code=AR-STALE-CREDIT-BALANCE', 41)
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
   2. dbo.sp_rpt_ExceptionCenter_Summary — add 2 new INSERT blocks
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923D', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923D;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Summary', 'sp_rpt_ExceptionCenter_Summary_OLD_20260923D';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary
    @DateFrom  date,
    @DateTo    date,
    @AsOfDate  date = NULL /* aging reference date for VOU-STALE-OUTSTANDING-
        CHECKS AND (new, this pass) AR-STALE-CREDIT-BALANCE; defaults to
        @DateTo when omitted, matching sp_rpt_DataHealthCheck's @AsOfDate =
        @DateTo precedent — see sql/16 header note "REVISION 2026-09-23C". */
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @AsOf  datetime = GETDATE(); /* report-GENERATED-at timestamp,
        returned as-is in every row's AsOf output column — wall-clock "when
        was this report run", unrelated to the stale-aging dates below.
        Do not repurpose this for aging logic; see @StaleAsOf. */
    DECLARE @StaleAsOf datetime = CAST(ISNULL(@AsOfDate, @DateTo) AS datetime);
        /* the actual as-of date BOTH VOU-STALE-OUTSTANDING-CHECKS and (new,
           this pass) AR-STALE-CREDIT-BALANCE age against — one shared
           variable, one shared "point-in-time aging reference, never
           hardcoded GETDATE()" concept, two independent consumers. */
    DECLARE @StaleDays int = 30; /* PLACEHOLDER pending developer's real
        treasury policy — see sql/16 header note "N-DAYS PLACEHOLDER".
        Bank-check clearing domain — unrelated to @CreditBalanceStaleDays. */
    DECLARE @CreditBalanceStaleDays int = 90; /* PLACEHOLDER pending
        developer's real write-off/refund policy — see THIS file's header
        note "N-DAYS PLACEHOLDER". AR credit-balance domain — unrelated to
        @StaleDays. */

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

    /* ---- AR-REVERSED-PAYMENTS (NEW, this pass): dbo.PaymentHeader is the
       complete, current AR reversal trail — see header note. Status=
       'REVERSED' + ReversedBy + ReversedDate are populated together, only by
       sp_ReversePaymentClient (a write proc; not called here). ValueAtRisk =
       PaymentHeader.TotalAmount directly (confirmed gross/net-safe — see
       header note; NEVER re-derived by summing ARPaymentDetails legs, which
       double-counts EWT on 5 of 43 headers today). Windowed on ReversedDate
       (the reversal event), matching VOU-REVERSED-VOUCHERS' windowing on
       CancelledDate rather than the original PaymentDate. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'AR-REVERSED-PAYMENTS',
        COUNT(*),
        SUM(ph.TotalAmount)
    FROM dbo.PaymentHeader AS ph
    WHERE ph.Status = 'REVERSED'
      AND ph.ReversedDate >= @Start AND ph.ReversedDate < @End;

    /* ---- AR-STALE-CREDIT-BALANCE (NEW, this pass): SAME source table and
       SAME sign filter as sp_rpt_DataHealthCheck Seq 14 (Balance < 0 on
       dbo.TransactionChargeSales) — deliberately not filtered by
       @DateFrom/@DateTo (would break the tie-out to Health Check's own
       always-global number; see header note "RECONCILIATION"). The AGING
       filter (DATEDIFF > @CreditBalanceStaleDays as of @StaleAsOf) is what
       narrows Health Check's full 205-row/₱2.08M population down to the
       subset THIS check actually flags — see header note for the exact
       live before/after figures and why that is correct, not a
       disagreement. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'AR-STALE-CREDIT-BALANCE',
        COUNT(*),
        SUM(ABS(t.Balance))
    FROM dbo.TransactionChargeSales AS t
    WHERE t.Balance < 0
      AND DATEDIFF(DAY, t.TransactionDate, @StaleAsOf) > @CreditBalanceStaleDays;

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
   3. dbo.sp_rpt_ExceptionCenter_Detail — add 2 new IF @ExceptionCode branches
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923D', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923D;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Detail', 'sp_rpt_ExceptionCenter_Detail_OLD_20260923D';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail
    @ExceptionCode varchar(50),
    @DateFrom      date,
    @DateTo        date,
    @AsOfDate      date = NULL /* aging reference date for
        VOU-STALE-OUTSTANDING-CHECKS AND (new, this pass)
        AR-STALE-CREDIT-BALANCE; defaults to @DateTo — see Summary proc /
        sql/16 header note "REVISION 2026-09-23C". */
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @StaleDays int = 30; /* PLACEHOLDER — see Summary proc / sql/16
        header note. Bank-check clearing domain. */
    DECLARE @CreditBalanceStaleDays int = 90; /* PLACEHOLDER — see Summary
        proc / this file's header note. AR credit-balance domain. */
    DECLARE @StaleAsOf datetime = CAST(ISNULL(@AsOfDate, @DateTo) AS datetime);
        /* declared ONCE here, shared by VOU-STALE-OUTSTANDING-CHECKS and
           AR-STALE-CREDIT-BALANCE — see Summary proc note. */

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

    /* ==== AR-REVERSED-PAYMENTS (NEW, this pass) — one row per reversed
       PaymentHeader. BranchCode is the CUSTOMER'S HOME branch (Customers.
       BranchCode), never TransactionChargeSales.BranchCode (the invoice's
       SELLING branch — a different dimension, see header note) — PaymentHeader
       itself has no branch column at all. Remarks is PaymentHeader's own
       free-text field, surfaced as-is (blank on today's one example) since
       there is no dedicated CancelReason-equivalent column on this table. ==== */
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

    /* ==== AR-STALE-CREDIT-BALANCE (NEW, this pass) — one row per flagged
       TransactionChargeSales invoice row (same grain as Health Check Seq 14,
       which is also row-level COUNT(*), not customer-aggregated — see header
       note). BranchCode is the CUSTOMER'S HOME branch (Customers.BranchCode),
       matching sp_rpt_AR_Aging's own convention, never
       TransactionChargeSales.BranchCode (the invoice's SELLING branch).
       DaysOpen = DATEDIFF(TransactionDate, @StaleAsOf) — the aging dimension
       neither Health Check nor AR Aging currently surfaces. PayStatus is
       included as-is for visibility but should NOT be trusted to identify
       these rows (confirmed live: always 'UNPAID' even with a negative
       Balance — see header data-quality note); only the Balance sign +
       WHERE filter identify membership. ==== */
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
-- Expect (verified live against DEV on 2026-09-23), 6 prior checks UNCHANGED:
--   SOD-SAME-PREP-APPR              Findings=1   ValueAtRisk=3688581595.84
--   VOU-CANCELLED-CHECKS            Findings=3   ValueAtRisk=334550.59
--   VOU-REVERSED-VOUCHERS           Findings=4   ValueAtRisk=349550.59
--   VOU-DUP-CHECKNO                 Findings=7   ValueAtRisk=583184.37
--   VOU-DUP-SUPPLIER-INVOICE        Findings=2   ValueAtRisk=1062922.85
--   EXP-REVERSALS                   Findings=4   ValueAtRisk=349550.59
--   VOU-STALE-OUTSTANDING-CHECKS    Findings=1   ValueAtRisk=26153.50 (as of @AsOfDate=2026-09-23)
-- Plus 2 NEW this pass:
--   AR-REVERSED-PAYMENTS            Findings=1   ValueAtRisk=9049.60
--     (PaymentHeaderID 4264, CustomerKey 00005571 MONTESOR RANULFO, home
--      branch '005', ReferenceNo 14107, ReversedBy 'juvie',
--      ReversedDate 2026-09-10 20:20:57 -- within the wide @From/@To window)
--   AR-STALE-CREDIT-BALANCE         Findings=169 ValueAtRisk=2039671.87
--     (of the full 205-row/2,079,610.34 population that ties exactly to
--      sp_rpt_DataHealthCheck Seq 14 today, 169 rows / 2,039,671.87 are aged
--      beyond 90 days as of @AsOfDate=2026-09-23 -- see header note
--      "RECONCILIATION" for the full before/after breakdown)

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'AR-REVERSED-PAYMENTS', @DateFrom = @From, @DateTo = @To;
-- Expect exactly 1 row: PaymentHeaderID 4264, TotalAmount 9049.60, ReversedBy
-- 'juvie', matches ARPaymentDetails sum for that header exactly (8179.20
-- INVOICE PAYMENT + 870.40 OVERPAY = 9049.60, no EWT leg on this header so no
-- gross/net gap for this particular example).

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'AR-STALE-CREDIT-BALANCE', @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect 169 rows (TOP 500 cap not hit), ORDER BY DaysOpen DESC so the FIRST
-- row is the OLDEST item, not the largest by value: CustomerKey 00008679 /
-- InvoiceNo J100662 / TransactionDate 2014-07-03 / DaysOpen 4465. The
-- LARGEST-BY-VALUE row (CustomerKey 00001802 / InvoiceNo 'C-000900' /
-- TransactionDate 2019-05-30 / CreditBalance 1,146,104.62 / DaysOpen 2673 --
-- ~55% of this check's total ValueAtRisk, see header) appears further down
-- this age-sorted list, not first. All 169 rows PayStatus = 'UNPAID'
-- (confirmed data-quality fact, not a bug in this query -- see header note).

-- Independent tie-out check against sp_rpt_DataHealthCheck Seq 14 (run
-- separately -- confirms the FULL population, not just the stale subset,
-- still matches):
-- SELECT COUNT(*), SUM(ABS(Balance)) FROM dbo.TransactionChargeSales WHERE Balance < 0;
-- Expect 205 / 2079610.34 -- matches Seq 14 exactly.

-- Fails loudly, does not silently return empty:
-- EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'NOT-A-REAL-CODE', @DateFrom = @From, @DateTo = @To;
*/
