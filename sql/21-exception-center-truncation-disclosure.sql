/* ============================================================================
   CORE REPORTING PORTAL — EXCEPTION CENTER: TRUNCATION DISCLOSURE 2026-09-26
   Target: CORECSERP_002_DEV. COREX001 requires explicit developer sign-off
   per DB change protocol (production-value data) — applied separately, only
   after this developer's go-ahead each time.

   WHAT THIS FIXES
   ----------------------------------------------------------------------------
   sp_rpt_ExceptionCenter_Detail caps every branch at SELECT TOP (500) — a
   sane guard against returning an unbounded result set to a browser modal.
   On CORECSERP_002_DEV's small dev dataset this cap never actually bites
   (every check's Findings count is well under 500). On COREX001's
   production-scale data it does: SALES-CREDIT-LIMIT-BREACH has 3,218
   findings there, so the drill-down modal was silently showing only the
   first 500 (summing to ₱31.8M) with NO indication it was partial, while the
   summary card correctly reported the true ₱108.8M across all 3,218 — a
   silent Summary/Detail disagreement, exactly the failure mode this whole
   review process exists to catch, just surfaced by data volume instead of
   a coding mistake.

   THE FIX — every one of the 19 SELECT TOP (500) branches in
   sp_rpt_ExceptionCenter_Detail now also emits a "TotalMatchCount" sentinel
   column: CAST(COUNT(*) OVER() AS int). A window function counts the FULL
   matching population (before TOP truncates), the same on every returned
   row. Confirmed safe to add to every branch: none of the 19 outer
   SELECT TOP (500) statements has its own DISTINCT or GROUP BY (the one
   branch, VOU-DUP-SUPPLIER-INVOICE, that does use GROUP BY does so only
   inside an upstream derived subquery, not in the same SELECT as the TOP).

   Data/ReportRepository.cs's GetExceptionCenterDetailAsync special-cases
   this exact column name: captures its value once into
   ReportResultSet.TotalRowCount and strips it out of the normal
   Columns/Rows so it never renders as a spurious data column. Models/
   ReportCenterModels.cs's ReportResultSet gained a nullable TotalRowCount
   int. wwwroot/js/drilldown-modal.js's shared appendSection() (used by BOTH
   Health Check and Exception Center) now shows a visible "showing top N of
   M, narrow the date range" notice whenever totalRowCount is present and
   exceeds the returned row count — Health Check's own checks don't emit
   this sentinel yet, so they render exactly as before, zero behavior change.

   Summary proc is untouched — its Findings/ValueAtRisk already come from a
   plain COUNT(*)/SUM(*) with no cap, so it was never the source of the
   disagreement; only Detail needed this.

   VERIFICATION PERFORMED
   ----------------------------------------------------------------------------
   - dotnet build: 0 warnings, 0 errors (C#/DTO changes compile clean).
   - node --check on drilldown-modal.js: syntax OK.
   - Applied to CORECSERP_002_DEV; re-ran the full summary proc and confirmed
     every one of the 19 checks' Findings/ValueAtRisk unchanged (this script
     only adds a column to Detail, never touches Summary or any WHERE clause).
   - Ran Detail for SALES-CREDIT-LIMIT-BREACH (464 findings on DEV, under the
     500 cap) and confirmed TotalMatchCount=464 on every row, matching
     rows.length exactly — no false-positive truncation notice when nothing
     is actually truncated.
============================================================================ */

-- Preserve the pre-disclosure version, don't drop it, per DB change protocol.
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260926B', 'P') IS NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Detail', 'sp_rpt_ExceptionCenter_Detail_OLD_20260926B';
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

    /* ==== Unknown @ExceptionCode — fail loudly ==== */
    RAISERROR('sp_rpt_ExceptionCenter_Detail: unknown or not-yet-implemented @ExceptionCode ''%s''.', 16, 1, @ExceptionCode);
END
GO

/* ============================================================================
   SMOKE TEST
============================================================================ */
/*
EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode='SALES-CREDIT-LIMIT-BREACH', @DateFrom='2020-01-01', @DateTo='2026-12-31';
-- CORECSERP_002_DEV: expect 464 rows, TotalMatchCount=464 on every row (no
-- truncation — cap never bites on dev-sized data).
-- COREX001 (after separate developer sign-off to apply there): expect 500
-- rows returned, TotalMatchCount=3218 on every row — this is what makes the
-- drilldown modal show "showing top 500 of 3,218" instead of silently
-- summing to a partial, disagreeing total.
*/
