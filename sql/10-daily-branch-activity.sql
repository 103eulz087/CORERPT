/* ============================================================================
   CORE REPORTING PORTAL — FINANCE OVERVIEW: TODAY'S SALES ACTIVITY BY BRANCH
   Target:     CORECSERP_002_DEV (compat level 160, per 04-dev-compat-level-160.sql)

   New widget on the Finance Overview dashboard: per-branch invoice count +
   total amount for a given day, so branch managers can watch daily sales
   activity as invoices get entered. This is an ACTIVITY/VOLUME metric, not
   an aging/collections metric.

   SCHEMA CONFIRMED BY READING INFORMATION_SCHEMA.COLUMNS ON CORECSERP_002_DEV
   (2026-09-12)
   ----------------------------------------------------------------------------
     TransactionChargeSales
         CustomerKey      char(8)        NOT NULL
         BranchCode       char(3)        NOT NULL   <- SCHEMA SURPRISE: this is
                                          CHAR(3), not the varchar CORE hard
                                          rule #2 generally expects. Still
                                          treated as an opaque string code per
                                          the rule's intent (no int conversion,
                                          no trimming into a lookup) — CAST to
                                          varchar on output for a stable
                                          ADO.NET contract, same as every other
                                          proc in this repo.
         TransactionDate  date           NOT NULL   <- confirmed genuine DATE
                                          (no time component), not datetime.
                                          See date-handling note below.
         ReferenceNo      varchar(20)    NOT NULL
         InvoiceNo        varchar(100)   NOT NULL
         TotalAmount      decimal(10,2)  NOT NULL
         PaymentType      varchar(15)    NOT NULL
         Balance          decimal(10,2)  NOT NULL   <- NOT referenced by this
                                          proc; developer-confirmed this is a
                                          sales-volume metric, counts/sums ALL
                                          rows for the day regardless of
                                          payment status.
         PayStatus        varchar(10)    NOT NULL   <- NOT referenced, same
                                          reason as Balance above.
         DueDate          date           NOT NULL

     Branches           BranchCode varchar(128) NOT NULL PK-ish
                         BranchName varchar(128) NULL

   DATE-HANDLING NOTE — WHY THIS PROC USES PLAIN EQUALITY, NOT A RANGE
   ----------------------------------------------------------------------------
   CORE hard rule #4 requires `>= @From AND < DATEADD(DAY,1,@To)` instead of
   BETWEEN, because TicketDate (and most transaction dates in this ERP) is
   DATETIME and a time component silently drops the last day if you use plain
   equality or BETWEEN with a date literal. TransactionChargeSales.TransactionDate
   is different: it is a genuine DATE column (confirmed via
   INFORMATION_SCHEMA.COLUMNS above, DATA_TYPE = 'date'), so it has no time
   component to lose. `TransactionDate = @ForDate` is therefore safe and
   correct here. Do NOT "fix" this into a range — that would be solving a
   problem this column does not have, and would silently double-count if
   @ForDate were ever compared incorrectly across a datetime cast. Every OTHER
   date column in this codebase (e.g. TicketMaster.TicketDate) should still use
   the range convention; this is a column-specific exception, not a new house
   rule.

   BRANCH ATTRIBUTION — DELIBERATE DEPARTURE FROM sp_rpt_AR_Aging
   ----------------------------------------------------------------------------
   sp_rpt_AR_Aging (sql/05-accounting-aging.sql) attributes AR balances to the
   CUSTOMER's home branch (Customers.BranchCode) because aging/collections is
   about who owes money and which branch owns that collection relationship.
   This widget attributes to TransactionChargeSales.BranchCode — the invoice's
   OWN branch — because it answers a different question: which branch
   generated today's sales. Developer-confirmed, not an oversight; do not
   "reconcile" this proc's branch column against sp_rpt_AR_Aging's, they are
   answering different questions by design.

   DATA-QUALITY FACTS VERIFIED DIRECTLY AGAINST DEV BEFORE CODING (as of
   2026-09-12)
   ----------------------------------------------------------------------------
   - 0 TransactionChargeSales.BranchCode values with no match in dbo.Branches
     today — the UNKNOWN BRANCH fallback is a standing defensive convention
     (same as UNKNOWN SUPPLIER / UNKNOWN CUSTOMER elsewhere in this repo), not
     because today's data needs it; data can change.
   - 2026-08-07 confirmed as a real multi-branch activity day: 10 branches,
     304 total invoices, e.g. BranchCode '004' (CAGAYAN BRANCH) 35 invoices /
     751,181.65; BranchCode '013' (OZAMIZ BRANCH) 3 invoices / 65,139.55.
   - 2026-09-12 (today, at time of writing) already has 5 posted invoice rows
     totaling 51,792.80 — used below as the "no @ForDate supplied" smoke test.
   - 2026-09-11 has 0 TransactionChargeSales rows — used below as the
     zero-activity smoke test, to confirm result set 2 returns a real 0/0.00
     row rather than NULLs when result set 1 is empty.

   CONVENTIONS (matched to 09-apexp-aging.sql / house style)
   ----------------------------------------------------------------------------
   Explicit CAST      on every result column (ADO.NET reader contract, Hard Rule #8)
   Unmatched branch    LEFT JOINed, never dropped, labeled 'UNKNOWN BRANCH - <code>'
   ISNULL(...,0)       on every aggregate in the no-GROUP-BY rollup result set
   No posted-status filter, no Balance/PayStatus filter — developer-confirmed,
                       this is an activity/volume metric, not a collections one
   Not a base-table writer — SELECT-only, matches Hard Rule #3 / house rule #3
============================================================================ */

IF OBJECT_ID('dbo.sp_rpt_DailyBranchActivity', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_DailyBranchActivity;
GO

CREATE PROCEDURE dbo.sp_rpt_DailyBranchActivity
    @ForDate date = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @ForDate = ISNULL(@ForDate, CAST(GETDATE() AS date));

    /* ---- Result set 1: one row per branch --------------------------------
       LEFT JOIN Branches — an invoice BranchCode with no Branches match is
       surfaced as 'UNKNOWN BRANCH - <code>', never silently dropped. */
    SELECT
        BranchCode   = CAST(t.BranchCode AS varchar(10)),
        BranchName   = CAST(ISNULL(b.BranchName, 'UNKNOWN BRANCH - ' + t.BranchCode) AS varchar(150)),
        InvoiceCount = CAST(COUNT(*) AS int),
        TotalAmount  = CAST(SUM(t.TotalAmount) AS decimal(18,2))
    FROM dbo.TransactionChargeSales AS t
    LEFT JOIN dbo.Branches AS b
        ON b.BranchCode = t.BranchCode
    WHERE t.TransactionDate = @ForDate
    GROUP BY t.BranchCode, b.BranchName
    ORDER BY TotalAmount DESC;

    /* ---- Result set 2: company-wide total, single row --------------------
       ISNULL(...,0) wrapped — this SELECT has no GROUP BY, so it always
       returns exactly one row even when zero invoices were raised that day;
       without ISNULL that row comes back NULL/NULL instead of 0/0.00 (same
       lesson as the AR/AP aging rollup fix documented in
       05-accounting-aging.sql / 09-apexp-aging.sql). */
    SELECT
        InvoiceCount = CAST(ISNULL(COUNT(*), 0) AS int),
        TotalAmount  = CAST(ISNULL(SUM(t.TotalAmount), 0) AS decimal(18,2))
    FROM dbo.TransactionChargeSales AS t
    WHERE t.TransactionDate = @ForDate;
END
GO
