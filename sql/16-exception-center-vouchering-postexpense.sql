/* ============================================================================
   CORE REPORTING PORTAL — EXCEPTION CENTER (Build Order Step 2)
   Target: CORECSERP_002_DEV only (never staging without asking).

   Scope of THIS script: Vouchering + Post Expense categories ONLY, per the
   brief's build order. Segregation of Duties (sql/15-exception-center.sql)
   is already shipped and reviewed and is NOT touched here — this script only
   ADDS new ExceptionDefinition rows and new IF @ExceptionCode branches to the
   two existing procs, following the exact same pattern as the SOD check.

   ----------------------------------------------------------------------------
   SCHEMA CONFIRMED LIVE ON CORECSERP_002_DEV BEFORE WRITING THIS (2026-09-23)
   ----------------------------------------------------------------------------

   dbo.sp_CancelledChequesCS (OBJECT_ID confirmed to exist) — READ via
   OBJECT_DEFINITION before writing anything. Conclusion: this is a WRITE proc
   (the actual cancel-a-check action used by the ERP's UI) — it updates
   CheckVoucher, APAccounts/ExpenseMaster, SupplierLedger, TicketMaster/
   TicketDetails (reversal ticket), PaymentReversalAudit, CheckVoucherCancelled,
   and calls sp_ReverseTicketsAP / sp_BankRecon_VoidOC inside a transaction.
   Per CLAUDE.md hard rule #9 / db-change-protocol, a reporting proc NEVER
   calls a write proc like this. The brief's instruction to "reuse/extend
   sp_CancelledChequesCS if it already returns what's needed" is satisfied
   differently: this write proc's SIDE EFFECTS already land in plain tables
   that a read-only report can safely SELECT from directly —
   dbo.CheckVoucher (isErrorCorrect/CancelledBy/CancelledDate/CancelReason
   columns persist permanently on the row itself, confirmed live: cancelled
   VoucherIDs 638/639/646 are still present in CheckVoucher, fully detailed,
   with isErrorCorrect=1) and dbo.PaymentReversalAudit (a dedicated,
   append-only audit trail: AuditID, VoucherID varchar(10), SupplierID,
   VoucherType ('PURCHASE'|'EXPENSE'), ReferenceNumber, CancelReason,
   CancelledBy, CancelledDate). Checks below read these tables, not the proc.

   dbo.CheckVoucher: SequenceNumber decimal, VoucherID decimal, SupplierID
     varchar(50), ReferenceNumber varchar(20), PaidTo varchar(150), CheckNo
     varchar(100), CheckDate date, Particulars varchar(5000), Amount money,
     PreparedBy/VerifiedBy/NotedBy/PaymentApprovedBy/PaymentReceivedBy
     varchar(50), OfficialReceiptNo varchar(50), VoucherType varchar(50)
     (observed: always 'CHECK' — does NOT distinguish PURCHASE/EXPENSE, that
     lives on PaymentReversalAudit.VoucherType / APPaymentDetails.PaymentMethod
     instead), DateReceived/DateAdded/DateUpdate date, isErrorCorrect bit,
     isLiquidation bit, CancelledBy varchar(50), CancelledDate datetime,
     CancelReason varchar(300), ControlNo varchar(100), CreditGLCode
     varchar(100) (the GL bank-cash account credited when the check is
     issued — this IS "the bank account" for this check's purposes; joins to
     dbo.BankCOA.AccountCode -> Bank/Description for a human-readable bank
     name). NO BranchCode column exists on CheckVoucher at all (data-quality
     gap, see note below) and NO general Status column exists — the only
     lifecycle state captured directly on this table is the binary
     isErrorCorrect (cancelled or not); there is no 'PREPARED'/'RELEASED'
     enum here.

   dbo.CashVoucher: same shape as CheckVoucher minus CheckNo/CheckDate/
     CancelledBy/CancelledDate/CancelReason (those three cancellation-detail
     columns do NOT exist on CashVoucher — confirmed live: VoucherID 644 is
     a cancelled CashVoucher row (isErrorCorrect=1) with nowhere on the table
     itself to record who/when/why; that detail lives ONLY in
     PaymentReversalAudit for cash-paid reversals. dbo.CashVoucherCancelled
     exists as a parallel table to CheckVoucherCancelled but is EMPTY (0 rows)
     even though CashVoucher has 1 genuinely cancelled row — confirms
     CashVoucherCancelled's write path (sp_CancelledCashVoucher) was not
     actually the one used for that reversal; PaymentReversalAudit is the
     only complete, current trail and is used below instead of either
     *Cancelled table.

   dbo.PaymentReversalAudit: AuditID int, VoucherID varchar(10), SupplierID
     varchar(40), VoucherType varchar(20) ('PURCHASE'|'EXPENSE' — this is the
     AP PAYMENT CATEGORY, not CHECK vs CASH), ReferenceNumber varchar(20),
     CancelReason varchar(300), CancelledBy varchar(50), CancelledDate
     datetime. NO Amount column — joined back to CheckVoucher/CashVoucher by
     VoucherID+SupplierID below to recover the peso amount, confirmed live
     with 0 VoucherID collisions between the two source tables (VoucherID
     appears to be a single shared sequence across CHECK and CASH vouchers).

   dbo.APPaymentDetails: VoucherID varchar(10), SupplierID varchar(50),
     ReferenceNumber char(5), BranchCode char(3), InvoiceNo varchar(100),
     InvoiceDate date, Amount decimal, PaymentType varchar(20) ('INVOICE
     PAYMENT'/'EXPENSE PAYMENT' = principal leg; 'EWT'/'DISCOUNT'/
     'RETURNALLOWANCES'/'VARIANCE' = adjustment legs on the SAME voucher),
     PaymentMethod varchar(20) ('PURCHASE'|'EXPENSE'), VoucherType varchar(20)
     ('CHECK'|'CASH'|'TELEGRAPHIC' — confirmed live, unlike CheckVoucher's own
     VoucherType column which is always 'CHECK'), DebitGLCode/CreditGLCode,
     TicketNumber, SequenceReferenceNumber, BatchReferenceID, Variance. This
     is the ONLY table found that carries BranchCode for an AP payment voucher
     — confirmed live (0 vouchers with >1 distinct BranchCode across their
     APPaymentDetails lines), so it is used below, via OUTER APPLY, to
     backfill a best-effort BranchCode onto CheckVoucher/CashVoucher rows for
     display. NOT every CheckVoucher row resolves a BranchCode this way
     (confirmed live: 5 of 17 current rows — mostly isLiquidation=1 cash-
     advance-liquidation checks — have no matching APPaymentDetails row at
     all); those display blank rather than a guessed value. This is a real
     schema gap (CheckVoucher itself carries no branch dimension) worth
     flagging to the developer, in the same spirit as the after-hours gap
     documented in sql/15-exception-center.sql.

   dbo.BankCOA: AccountCode varchar(50) (matches CheckVoucher.CreditGLCode),
     Description varchar(256), Bank varchar(50) (short bank name, e.g. 'BDO').

   dbo.BankStatementRecon: ReconID int, BranchCode varchar(5), AccountCode
     varchar(20), PeriodEnd date, ItemType varchar(5) (observed values: 'OC'
     = Outstanding Check/disbursement, 'DIT' = Deposit In Transit),
     ReferenceNo varchar(150) (confirmed live = the paying voucher's
     VoucherID, e.g. '683'), ItemDate date (confirmed live = the check's own
     CheckDate, NOT a bank-statement date), Payee varchar(200), Amount
     decimal, IsResolved bit (confirmed live: this is the closest thing this
     schema has to a check "cleared" flag — flips to 1, with ResolvedDate/
     ResolvedBy populated, once the item is matched during bank
     reconciliation), SourceModule varchar(20) (e.g. 'AP-PAYMENT',
     'CASH-ADVANCE'), SourceRef varchar(50) (confirmed live = the paying
     voucher's ReferenceNumber, e.g. '17791').

   ----------------------------------------------------------------------------
   CHECK-STATUS LIFECYCLE — CONFIRMED, NOT ASSUMED (brief explicitly asked to
   verify this before deciding what "beyond N days" means)
   ----------------------------------------------------------------------------
   There is NO three-stage Prepared -> Released -> Cleared enum anywhere in
   this schema. What actually exists, confirmed against live data:
     1. PREPARED/ISSUED: a CheckVoucher row is created (CheckDate = the date
        written on the check) and a matching dbo.BankStatementRecon row is
        inserted with ItemType='OC', IsResolved=0 — this happens at the same
        time the check is prepared, not at a separate "release" step. There
        is no distinct "released" state observed anywhere.
     2. CLEARED: BankStatementRecon.IsResolved flips to 1 (with ResolvedDate/
        ResolvedBy) once the bank reconciliation process matches the item
        against an actual bank statement line.
   dbo.BankReconHeader.Status is always 'OPEN' on all 25 rows currently in
   DEV (LockedBy/LockedDate never populated) — this table tracks the monthly
   reconciliation SESSION, not the individual check's clearing state, and adds
   nothing to this check's logic.
   CONCLUSION: "checks prepared but not released/cleared beyond N days" is
   built below as "checks whose BankStatementRecon 'OC' item is still
   IsResolved=0, aged from CheckDate to today" — i.e. Prepared-to-Cleared
   directly, no separate Released stage exists to check for. This is reported
   here as the schema finding, not silently assumed.
   Also confirmed live: not every 'OC' row in BankStatementRecon corresponds
   to a check — AP payments made by cash or telegraphic transfer also produce
   'OC' rows (same disbursement-outstanding concept, different payment
   instrument). This check below INNER JOINs to CheckVoucher specifically so
   only genuine checks are counted, which naturally excludes those.

   N-DAYS PLACEHOLDER (documented as a placeholder, per the after-hours-window
   / AR-risk-threshold precedent in this codebase — NOT the developer's real
   house number)
   ----------------------------------------------------------------------------
   @StaleDays = 30 is used below. Rationale for picking 30 as a starting
   placeholder: it is well short of the ~180-day Philippine bank check
   staleness convention (checks are generally not honored after 6 months), so
   it surfaces items early enough for a cash-management review to act, without
   being so tight that ordinary 1-2 week clearing lag floods the dashboard.
   Confirmed live: the single oldest currently-unresolved matched check is 51
   days old (VoucherID 636, CheckNo 100525689, BDO PESO1, dated 2026-08-03) —
   a real, not hypothetical, finding. REVISIT with the developer's actual
   treasury policy before treating 30 as authoritative.

   ----------------------------------------------------------------------------
   POST EXPENSE — "SIX-COLUMN TRACKING SCHEMA" CLAIM CHECKED AGAINST LIVE
   SCHEMA, NOT ASSUMED — PARTIALLY BUILDABLE, PARTIALLY NOT
   ----------------------------------------------------------------------------
   Read dbo.ExpenseSummary's FULL column list live via INFORMATION_SCHEMA.
   COLUMNS (23 columns total) and skimmed sql/09-apexp-aging.sql's existing
   schema notes on this table (that file documents 09-12 findings; it does
   NOT mention any "six-column tracking" or "edit-tracking" feature — grepped
   sql/14-agent-scorecard.sql and docs/brief-agent-scorecard.md too, no hits
   either). The brief's premise does not match what is actually on this
   table. What genuinely exists: AddedBy varchar(30) / DateTimeAdded datetime
   / UpdatedBy varchar(30) / DateTimeUpdated datetime — the same plain
   created/updated CRUD-audit columns present on many tables in this schema,
   NOT a dedicated edit-count or reversal-count feature. Confirmed live: 376
   of 514 ExpenseSummary rows (73%) have DateTimeUpdated <> DateTimeAdded —
   this is NOT rare/suspicious, it is the NORMAL side effect of the ordinary
   apply-a-payment workflow updating Balance/AmountPaid/Status on the same
   row (per sp_CancelledChequesCS's own EXPENSE-flow UPDATE statements, which
   touch these exact columns during ordinary reversal AND during ordinary
   payment application). There is no history/versioning table behind
   ExpenseSummary, so:
     - You cannot count HOW MANY times a row was edited (UpdatedBy/
       DateTimeUpdated only ever hold the LAST touch, overwritten each time).
     - You cannot distinguish a "manual correction" edit from a routine
       payment-application update (both touch the same two columns, and
       there is no before/after value to compare).
   CONCLUSION: a genuine "high edit rate per user" check (the docs/erp-
   reporting-portal-concept.html "High edit rate" mockup pattern) is NOT
   BUILDABLE against this table with current data — it would either flag 73%
   of all expense entries as "edited" (pure noise, indistinguishable from
   normal payment processing) or require guessing at a meaningless threshold.
   NOT BUILT, no ExceptionDefinition row seeded for it, per the after-hours-
   postings precedent (name it, don't force it).
   The REVERSALS half of Post Expense check #1 IS genuinely buildable and
   IS built below (EXP-REVERSALS), reusing dbo.PaymentReversalAudit filtered
   to VoucherType='EXPENSE' — this is real audit-trail data, not derived from
   the unreliable edit-timestamp signal above.

   ----------------------------------------------------------------------------
   DATA-QUALITY / SEVERITY-RELEVANT FACTS CONFIRMED LIVE BEFORE CODING
   ----------------------------------------------------------------------------
   - CheckVoucher currently has 17 rows total, 3 cancelled (isErrorCorrect=1),
     all VoucherType='CHECK'. This is a small DEV dataset — findings below are
     real but low-volume; do not read absolute counts as production-scale.
   - Confirmed a live, real duplicate: CheckNo '100525689' on CreditGLCode
     '101020101' (BDO PESO1) appears on 8 CheckVoucher rows total (7 of them
     NOT cancelled). This looks like DEV test data reusing a default/dummy
     check-number value rather than a live-system fraud pattern, but the
     detection logic itself is correct and would catch a genuine duplicate in
     production the same way — flagged as a data-quality observation, not a
     reason to weaken the check.
   - Confirmed a live, real duplicate: SupplierID/InvoiceNo pairs
     ('000001'/'SI-1000065428', '000002'/'1175', '000067'/'SOA#5625',
     '000125'/'SI-202511487 CHMDM') each paid across 2-3 distinct VoucherIDs.
     Confirmed this system supports legitimate multi-tranche/partial invoice
     payment (Status='PARTIAL' exists on ExpenseMaster/APAccounts), so this
     check is Severity=Warning (needs a human look), not Critical (not
     inherently fraud) — see per-check severity rationale below.
   - Confirmed all 4 PaymentReversalAudit rows currently in DEV are
     VoucherType='EXPENSE' (0 are 'PURCHASE' today) — so VOU-REVERSED-
     VOUCHERS (all types) and EXP-REVERSALS (EXPENSE-only subset) will show
     identical counts/values against TODAY's DEV data. This is expected, not
     a bug: the two checks are logically distinct (different WHERE filter,
     different audiences — Vouchering vs Post-Expense) and will diverge the
     moment a PURCHASE-type reversal exists.

   ----------------------------------------------------------------------------
   CROSS-CHECK OVERLAP — DISCLOSED, NOT A BUG, BUT DO NOT NAIVELY SUM CARDS
   ----------------------------------------------------------------------------
   VOU-CANCELLED-CHECKS, VOU-REVERSED-VOUCHERS, and EXP-REVERSALS structurally
   overlap. Confirmed live: dbo.sp_CancelledChequesCS writes CheckVoucher.
   isErrorCorrect=1 AND inserts the matching dbo.PaymentReversalAudit row in
   the SAME transaction, so every check-type cancellation lands in BOTH
   checks' source data. Confirmed live on today's DEV data: all 3
   CheckVoucher rows with isErrorCorrect=1 (VoucherIDs 638, 639, 646) have an
   exactly matching PaymentReversalAudit row (same VoucherID, VoucherType=
   'EXPENSE') — i.e. VOU-CANCELLED-CHECKS' 3 findings today are a strict
   subset of VOU-REVERSED-VOUCHERS' 4 findings (which also picks up VoucherID
   644, a cancelled CashVoucher with no CheckVoucher-side equivalent) and of
   EXP-REVERSALS' 4 findings (since all 4 PaymentReversalAudit rows today are
   VoucherType='EXPENSE'). This is not a bug — no current dashboard tile or
   Excel export sums ValueAtRisk/Findings across exception codes — but a
   FUTURE "total value at risk" rollup, KPI tile, or export MUST NOT naively
   SUM(ValueAtRisk) or SUM(Findings) across VOU-CANCELLED-CHECKS,
   VOU-REVERSED-VOUCHERS, and EXP-REVERSALS without de-duplicating by
   VoucherID first, or it will double- (or triple-) count the same
   cancelled check. See docs/brief-exception-center.md, Vouchering section,
   for the same disclosure aimed at the module owner.

   ----------------------------------------------------------------------------
   SEVERITY DECISIONS (documented per developer's ask to justify each)
   ----------------------------------------------------------------------------
   - VOU-CANCELLED-CHECKS: Warning. Every cancelled check in current data
     carries a captured reason ('wrong payment', 'wrong date') via a
     deliberate, audited control action (sp_CancelledChequesCS requires
     @parmreason/@parmuser) — this is a working error-correction control, not
     an absence of one. Worth monitoring for volume/pattern, not an automatic
     red alert.
   - VOU-REVERSED-VOUCHERS / EXP-REVERSALS: Warning, same reasoning — reuses
     the same audited PaymentReversalAudit trail.
   - VOU-DUP-CHECKNO: Critical. A physical check number should be unique
     within one bank account by construction (it's a serial number on a
     chequebook) — a genuine duplicate is either a serious data-entry defect
     in check-number assignment or a check-fraud/kiting signal, and unlike
     the reversal checks above there is no corresponding audited control
     action that explains it away. Excludes cancelled vouchers (isErrorCorrect
     =1) since a voided check's number is expected to sit unused, not counted
     as "in use" by two payments.
   - VOU-DUP-SUPPLIER-INVOICE: Warning, not Critical — see data-quality note
     above: this system has legitimate multi-tranche payment support, so
     "same invoice on 2+ vouchers" is a review trigger, not proof of a
     double-payment.
   - VOU-STALE-OUTSTANDING-CHECKS: Warning — a cash-management/reconciliation
     hygiene signal, not a control failure or fraud indicator by itself.

   DB change protocol: the two shared procs already exist in DEV (built in
   15-exception-center.sql, revised same day). Per CLAUDE.md /
   db-change-protocol, the prior definitions are preserved under an
   _OLD_<timestamp> name rather than dropped, so they remain queryable.

   ----------------------------------------------------------------------------
   REVISION 2026-09-23C — accounting-reviewer findings, both fixed
   ----------------------------------------------------------------------------
   1. VOU-DUP-SUPPLIER-INVOICE (Summary + Detail) counted cancelled voucher
      legs as if they were live duplicate payments. Traced against
      ExpenseMaster.AmountPaid (AP subledger ground truth): 3 of 5 reported
      pairs had only ONE live voucher once the cancelled leg (CheckVoucher/
      CashVoucher.isErrorCorrect=1) is excluded — pure false positives; 1 pair
      had 2 genuinely live vouchers but was inflated by also summing the
      cancelled leg; 1 pair was unaffected. Fixed by joining APPaymentDetails
      to CheckVoucher/CashVoucher on VoucherID+SupplierID (same pattern as
      VOU-REVERSED-VOUCHERS/EXP-REVERSALS below) and excluding any leg whose
      owning voucher has isErrorCorrect=1, in BOTH the Summary aggregate and
      the Detail expansion, so the dashboard tile and its own drilldown can
      never disagree. NOTE: a leg with NO matching CheckVoucher/CashVoucher
      row at all (VoucherType='TELEGRAPHIC' legs live in dbo.TelegraphicVoucher
      instead, confirmed live to also carry its own isErrorCorrect column) is
      treated as live/uncancelled by this fix — TelegraphicVoucher is NOT
      joined here, matching the existing CheckVoucher/CashVoucher-only scope of
      VOU-REVERSED-VOUCHERS/EXP-REVERSALS elsewhere in this file. This is a
      known, documented gap, not a silent one: if a TELEGRAPHIC voucher is ever
      cancelled, none of the three checks in this file (VOU-REVERSED-VOUCHERS,
      EXP-REVERSALS, VOU-DUP-SUPPLIER-INVOICE) will currently detect it. Not
      fixed in this pass — flagged for the developer as a follow-up scope
      decision (extend the join three ways vs. accept the gap), since it
      touches more than the two specific bugs assigned here.
      Corrected result against live DEV data (2026-09-23): Findings 5 -> 2,
      ValueAtRisk $1,350,475.36 -> ~$1,062,922.85 (~21% overstatement removed).
   2. VOU-STALE-OUTSTANDING-CHECKS aged from GETDATE() (real-world today)
      instead of the report's own as-of date. The header's original claim that
      this matches sp_rpt_AR_Aging/sp_rpt_AP_Aging's "point-in-time" caveat was
      checked against sql/05-accounting-aging.sql directly and found
      INACCURATE: those procs age via a caller-supplied @AsOfDate parameter,
      never hardcoded GETDATE(), and sp_rpt_DataHealthCheck defaults
      @AsOfDate = @DateTo when the caller omits it — THAT is the actual
      precedent. Fixed by adding @AsOfDate date = NULL to both Summary and
      Detail, defaulting to @DateTo when not supplied (matching
      sp_rpt_DataHealthCheck's pattern), and using one @StaleAsOf variable
      (declared once in Detail, not two separate GETDATE() calls) everywhere
      the aging math happens. The unrelated @AsOf variable in Summary (the
      generic "report generated at" timestamp returned in every row's AsOf
      column, consumed by Models/ExceptionCenterModels.cs) is left as
      GETDATE() — it is a different concept (wall-clock report-run time, not
      an aging reference date) and changing its meaning would have silently
      altered every OTHER exception code's AsOf value, not just this check's.
============================================================================ */


/* ============================================================================
   1. dbo.ExceptionDefinition — seed the 6 new checks from this pass
   (5 Vouchering + 1 Post Expense). No DDL change to the table itself.
============================================================================ */
MERGE dbo.ExceptionDefinition AS tgt
USING (VALUES
    ('VOU-CANCELLED-CHECKS',      'Vouchering',   'Cancelled checks',
     'Warning', 1, '/ExceptionCenter/Detail?code=VOU-CANCELLED-CHECKS', 20),
    ('VOU-REVERSED-VOUCHERS',     'Vouchering',   'Reversed payment vouchers (check & cash)',
     'Warning', 1, '/ExceptionCenter/Detail?code=VOU-REVERSED-VOUCHERS', 21),
    ('VOU-DUP-CHECKNO',           'Vouchering',   'Duplicate check number within the same bank account',
     'Critical', 1, '/ExceptionCenter/Detail?code=VOU-DUP-CHECKNO', 22),
    ('VOU-DUP-SUPPLIER-INVOICE',  'Vouchering',   'Duplicate supplier invoice number across vouchers (double-payment risk)',
     'Warning', 1, '/ExceptionCenter/Detail?code=VOU-DUP-SUPPLIER-INVOICE', 23),
    ('VOU-STALE-OUTSTANDING-CHECKS', 'Vouchering', 'Checks outstanding beyond N days (not yet cleared)',
     'Warning', 1, '/ExceptionCenter/Detail?code=VOU-STALE-OUTSTANDING-CHECKS', 24),
    ('EXP-REVERSALS',             'Post Expense', 'Post-expense payment reversals',
     'Warning', 1, '/ExceptionCenter/Detail?code=EXP-REVERSALS', 30)
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
   2. dbo.sp_rpt_ExceptionCenter_Summary — add 6 new INSERT blocks
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923C', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923C;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Summary', 'sp_rpt_ExceptionCenter_Summary_OLD_20260923C';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary
    @DateFrom  date,
    @DateTo    date,
    @AsOfDate  date = NULL /* aging reference date for VOU-STALE-OUTSTANDING-
        CHECKS; defaults to @DateTo when omitted, matching
        sp_rpt_DataHealthCheck's @AsOfDate = @DateTo precedent — see header
        note "REVISION 2026-09-23C". NOT the same thing as @AsOf below. */
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @AsOf  datetime = GETDATE(); /* report-GENERATED-at timestamp,
        returned as-is in every row's AsOf output column — wall-clock "when
        was this report run", unrelated to the stale-check aging date below.
        Do not repurpose this for aging logic; see @StaleAsOf. */
    DECLARE @StaleAsOf datetime = CAST(ISNULL(@AsOfDate, @DateTo) AS datetime);
        /* the actual as-of date VOU-STALE-OUTSTANDING-CHECKS ages against. */
    DECLARE @StaleDays int = 30; /* PLACEHOLDER pending developer's real
        treasury policy — see header note "N-DAYS PLACEHOLDER" above. */

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

    /* ---- VOU-CANCELLED-CHECKS: reads CheckVoucher's own cancellation columns
       (isErrorCorrect/CancelledBy/CancelledDate/CancelReason), NOT
       CheckVoucherCancelled (a redundant snapshot copy, and NOT
       dbo.sp_CancelledChequesCS (a write proc) — see header note. Windowed on
       CancelledDate (when the cancellation happened), not CheckDate. ---- */
    INSERT INTO #Result (ExceptionCode, Findings, ValueAtRisk)
    SELECT
        'VOU-CANCELLED-CHECKS',
        COUNT(*),
        SUM(cv.Amount)
    FROM dbo.CheckVoucher AS cv
    WHERE cv.isErrorCorrect = 1
      AND cv.CancelledDate >= @Start AND cv.CancelledDate < @End;

    /* ---- VOU-REVERSED-VOUCHERS: dbo.PaymentReversalAudit is the complete,
       current reversal trail for BOTH CheckVoucher- and CashVoucher-paid
       vouchers, ALL VoucherType ('PURCHASE' + 'EXPENSE') — see header note on
       why CheckVoucherCancelled/CashVoucherCancelled are NOT used (the latter
       is confirmed empty despite a real cancelled row existing). Amount is
       recovered by joining back to CheckVoucher/CashVoucher on VoucherID +
       SupplierID (PaymentReversalAudit itself carries no Amount column). ---- */
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

    /* ---- VOU-DUP-CHECKNO: same CheckNo reused on the same bank account
       (CreditGLCode) across 2+ NON-cancelled CheckVoucher rows. Windowed on
       CheckDate. Findings = number of flagged VOUCHER ROWS (each row
       participating in a duplicate group), matching the SOD check's
       one-row-per-flagged-unit convention. ---- */
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

    /* ---- VOU-DUP-SUPPLIER-INVOICE: same SupplierID + InvoiceNo paid across
       2+ DISTINCT VoucherIDs in dbo.APPaymentDetails (covers both PURCHASE
       and EXPENSE payment methods — the same table backs both flows).
       ValueAtRisk = PRINCIPAL legs only (PaymentType IN ('INVOICE PAYMENT',
       'EXPENSE PAYMENT')), deliberately excluding EWT/DISCOUNT/
       RETURNALLOWANCES/VARIANCE adjustment legs so the figure represents
       actual cash paid against the invoice, not inflated by its own
       adjustment lines. Findings = number of flagged (Supplier, Invoice)
       PAIRS, not voucher rows — the risk unit here is "this invoice was paid
       via multiple vouchers", not any single voucher line. Windowed on
       InvoiceDate.
       FIX 2026-09-23C: legs belonging to a CANCELLED voucher (CheckVoucher/
       CashVoucher.isErrorCorrect=1) are EXCLUDED before counting/summing —
       a voided-and-reissued voucher is not a second live payment. Without
       this, a legitimate cancel+reissue reads as a duplicate-payment finding
       and inflates ValueAtRisk by the cancelled leg's own amount. See header
       note "REVISION 2026-09-23C" for the traced-out before/after numbers.
       Legs with no matching CheckVoucher/CashVoucher row (TELEGRAPHIC-paid
       legs) are treated as live — see header note on the known
       TelegraphicVoucher gap shared with VOU-REVERSED-VOUCHERS/
       EXP-REVERSALS. ---- */
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

    /* ---- VOU-STALE-OUTSTANDING-CHECKS: BankStatementRecon 'OC' items still
       IsResolved=0, INNER JOINed to CheckVoucher (so cash/telegraphic 'OC'
       items are naturally excluded — see header note on the join key,
       confirmed live: ReferenceNo=VoucherID, SourceRef=ReferenceNumber).
       Aged from CheckDate to @StaleAsOf (= @AsOfDate, defaulting to @DateTo
       when the caller doesn't supply one) — this is a live, current-state
       snapshot (BankStatementRecon.IsResolved has no history), aged the SAME
       way sp_rpt_AR_Aging/sp_rpt_AP_Aging and sp_rpt_DataHealthCheck age
       their point-in-time balances: a caller-supplied as-of date, defaulting
       to the period end, NEVER a hardcoded GETDATE() — see header note
       "REVISION 2026-09-23C" (the original hardcoded-GETDATE() version would
       have silently reported staleness as of TODAY when run for a past
       period, which is wrong for historical Executive/Audit review).
       Windowed on CheckDate (checks ISSUED within the selected period);
       widen the date range to see older stale checks. ---- */
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

    /* ---- EXP-REVERSALS: same source as VOU-REVERSED-VOUCHERS, filtered to
       VoucherType='EXPENSE' only — the Post Expense-specific subset. See
       header note on why "edit rate" (the other half of the brief's Post
       Expense check #1) is NOT built. ---- */
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
   3. dbo.sp_rpt_ExceptionCenter_Detail — add 6 new IF @ExceptionCode branches
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923C', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923C;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Detail', 'sp_rpt_ExceptionCenter_Detail_OLD_20260923C';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail
    @ExceptionCode varchar(50),
    @DateFrom      date,
    @DateTo        date,
    @AsOfDate      date = NULL /* aging reference date for
        VOU-STALE-OUTSTANDING-CHECKS; defaults to @DateTo — see Summary proc /
        header note "REVISION 2026-09-23C". */
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @StaleDays int = 30; /* PLACEHOLDER — see Summary proc / header note. */
    DECLARE @StaleAsOf datetime = CAST(ISNULL(@AsOfDate, @DateTo) AS datetime);
        /* declared ONCE here, used everywhere below instead of calling
           GETDATE() twice inline — see header note "REVISION 2026-09-23C". */

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

    /* ==== VOU-CANCELLED-CHECKS ==== */
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

    /* ==== VOU-REVERSED-VOUCHERS ==== */
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

    /* ==== VOU-DUP-CHECKNO ==== */
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

    /* ==== VOU-DUP-SUPPLIER-INVOICE — expanded to voucher level for drilldown.
       FIX 2026-09-23C: uses the same LiveLegs (cancelled-leg-excluded) source
       as the Summary aggregate for BOTH identifying the flagged pairs AND
       expanding their rows, so this drilldown's row-level amounts always sum
       to exactly the Summary tile's ValueAtRisk — see header note "REVISION
       2026-09-23C". A cancelled voucher's leg is dropped entirely from this
       result set, not merely flagged, matching Summary's exclusion. ==== */
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

    /* ==== VOU-STALE-OUTSTANDING-CHECKS ==== */
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

    /* ==== EXP-REVERSALS ==== */
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

    /* ==== Unknown @ExceptionCode — fail loudly ==== */
    RAISERROR('sp_rpt_ExceptionCenter_Detail: unknown or not-yet-implemented @ExceptionCode ''%s''.', 16, 1, @ExceptionCode);
END
GO


/* ============================================================================
   SMOKE TEST
============================================================================ */
/*
DECLARE @From date = '2020-01-01', @To date = '2026-12-31';

-- NOTE on @AsOfDate in this smoke test: @To is deliberately a wide FUTURE date
-- (2026-12-31) so every other check sees the full historical window. Because
-- VOU-STALE-OUTSTANDING-CHECKS now defaults its aging reference to @DateTo
-- (per the fix below) rather than always GETDATE(), running with @To alone
-- would age stale checks as of 2026-12-31, not "today" — pass @AsOfDate
-- explicitly = today (2026-09-23 at verification time) to reproduce the
-- reviewer's original single-finding baseline. This is the CORRECT, intended
-- behavior post-fix, not a leftover bug: a caller who wants "as of today"
-- must say so, exactly like sp_rpt_DataHealthCheck.

EXEC dbo.sp_rpt_ExceptionCenter_Summary @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect (verified live against DEV on 2026-09-23):
--   SOD-SAME-PREP-APPR              Findings=1   ValueAtRisk=3688581595.84 (unchanged)
--   VOU-CANCELLED-CHECKS            Findings=3   ValueAtRisk=334550.59  (638+639+646, unchanged)
--   VOU-REVERSED-VOUCHERS           Findings=4   ValueAtRisk=349550.59  (+644 CASH, unchanged)
--   VOU-DUP-CHECKNO                 Findings=7   ValueAtRisk=583184.37  (CheckNo 100525689 / BDO PESO1, unchanged)
--   VOU-DUP-SUPPLIER-INVOICE        Findings=2   ValueAtRisk=1062922.85 (FIXED — was Findings=5 / 1350475.36;
--                                                  cancelled legs 646/639/644 excluded drops 3 pairs to 1 live
--                                                  voucher each (no longer flagged, and their sole surviving
--                                                  voucher's amount ties exactly to ExpenseMaster.AmountPaid:
--                                                  SI-1000065426=674.10, 1175=127597.22, SOA#5625=15000.00);
--                                                  Supplier 000001/SI-1000065428 stays flagged at its correct
--                                                  live-only total 1009.87 = 676 TELEGRAPHIC 500.00 + 680 CHECK
--                                                  509.87 (an EXPENSE-type invoice — ties exactly to
--                                                  ExpenseMaster.AmountPaid=1009.87); Supplier 000125/
--                                                  SI-202511487 CHMDM unchanged 1061912.98 = 677 500000.00 +
--                                                  678 561912.98 (a PURCHASE-type invoice — has no ExpenseMaster
--                                                  row at all, ties instead to APAccounts.AmountPaid=1061912.98,
--                                                  APAccounts.Balance=0.00, PayStatus='FULLYPAID')
--   VOU-STALE-OUTSTANDING-CHECKS    Findings=1   ValueAtRisk=26153.50   (VoucherID 636, 51 days as of
--                                                  @AsOfDate=2026-09-23 — matches the pre-fix baseline
--                                                  exactly when @AsOfDate = today, as expected)
--   EXP-REVERSALS                   Findings=4   ValueAtRisk=349550.59  (same 4 as VOU-REVERSED-VOUCHERS today — see header note)

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'VOU-CANCELLED-CHECKS', @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'VOU-REVERSED-VOUCHERS', @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'VOU-DUP-CHECKNO', @DateFrom = @From, @DateTo = @To;
EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'VOU-DUP-SUPPLIER-INVOICE', @DateFrom = @From, @DateTo = @To;
-- Expect exactly 2 pairs / 4 rows: Supplier 000001/SI-1000065428 (VoucherIDs 676 + 680, PrincipalPaid
-- 500.00 + 509.87, an EXPENSE-type invoice, sum ties to ExpenseMaster.AmountPaid=1009.87) and Supplier
-- 000125/SI-202511487 CHMDM (VoucherIDs 677 + 678, PrincipalPaid 500000.00 + 561912.98, a PURCHASE-type
-- invoice with no ExpenseMaster row — ties instead to APAccounts.AmountPaid=1061912.98). VoucherID 646
-- (cancelled) and the 639/644 legs of the other now-dropped pairs no longer appear at all.

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'VOU-STALE-OUTSTANDING-CHECKS', @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-23';
-- Expect exactly 1 row: VoucherID 636, DaysOutstanding = 51 (DATEDIFF(DAY, '2026-08-03', '2026-09-23')).

-- @AsOfDate / point-in-time regression check: rerun the stale check as of a date BEFORE VoucherID
-- 636 crossed the 30-day threshold (CheckDate 2026-08-03 + 30 days = 2026-09-02) and confirm it
-- drops out — proves aging now follows the caller's as-of date, not real-world GETDATE():
EXEC dbo.sp_rpt_ExceptionCenter_Summary @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-01';
-- Expect VOU-STALE-OUTSTANDING-CHECKS Findings=0, ValueAtRisk=NULL (DATEDIFF(DAY,'2026-08-03','2026-09-01')=29, not > 30).
EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'VOU-STALE-OUTSTANDING-CHECKS', @DateFrom = @From, @DateTo = @To, @AsOfDate = '2026-09-01';
-- Expect 0 rows, confirming Summary and Detail agree at the same @AsOfDate.
-- Also confirmed live: omitting @AsOfDate entirely with this same wide @To (2026-12-31) correctly
-- ages against @DateTo instead of GETDATE() — Findings jumps to 14 (many more checks cross 30 days
-- by 2026-12-31 than by today) — this is the intended default-to-@DateTo behavior, not a bug; callers
-- who want "as of today" must pass @AsOfDate = today (or a tighter @DateTo), exactly like
-- sp_rpt_DataHealthCheck's own @AsOfDate = @DateTo default.

EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'EXP-REVERSALS', @DateFrom = @From, @DateTo = @To;

-- Fails loudly, does not silently return empty:
-- EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'NOT-A-REAL-CODE', @DateFrom = @From, @DateTo = @To;
*/
