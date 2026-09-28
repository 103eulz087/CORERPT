/* ============================================================================
   CORE REPORTING PORTAL — PURCHASING: SUPPLIER PRICE COMPARISON
   (landed cost per kilo, by supplier, weekly / monthly / yearly)

   Brand-new object, first creation — nothing to preserve under an _OLD
   suffix. Target DB: COREX001 (sole default dev tier per CLAUDE.md).
   NOT applied to CORECSJFC2026_STAGING — ask first, every time.

   STATUS: WRITTEN, NOT YET APPLIED OR SMOKE-TESTED. It was authored in a
   session whose network policy blocked corex.itcoreapps.com:1433, so the
   column names below come from the schema notes ALREADY CONFIRMED LIVE in
   earlier scripts (cited per table), not from a fresh INFORMATION_SCHEMA
   read. Before relying on it: apply to COREX001, run the smoke tests at the
   bottom, and check the "VERIFY LIVE" items listed there.

   ----------------------------------------------------------------------------
   THE ASK
   ----------------------------------------------------------------------------
   The client wants to compare what each supplier's meat actually costs per
   kilo, bucketed weekly / monthly / yearly, so they can see who is cheaper,
   who is moving, and by how much. PO lines (PODETAILS) carry NO usable cost
   — PODETAILS.Cost = 0 and POSUMMARY.TotalCost = 0 on every live row
   (sql/19, "COST DATA-QUALITY FINDING"). The money is entered afterwards as
   ExpenseSummary invoices tagged with the PO's ShipmentNo. So:

       landed cost per kg = SUM(linked ExpenseSummary.Amount)
                            / SUM(PODETAILS.ActualQuantity)   (received kg)

   ----------------------------------------------------------------------------
   SOURCES (schema as confirmed live in prior scripts)
   ----------------------------------------------------------------------------
   dbo.POSUMMARY  (sql/19) ShipmentNo varchar(10), BranchCode char(3),
                  SupplierID varchar(30), Status varchar(20), DateOrder
                  datetime (real sub-day timestamps).
   dbo.PODETAILS  (sql/19) ShipmentNo varchar(10), OrderCode char(5)
                  (= Products.ProductCode), Quantity decimal(10,2) ordered,
                  ActualQuantity decimal(10,2) received, Unit — always 'kg'
                  live, so no UOM conversion.
   dbo.ExpenseSummary (sql/09, sql/16) ReferenceNumber varchar(10),
                  InvoiceNo varchar(150), SupplierID char(6), Description
                  varchar(300), Status varchar(50), Amount money, ExpenseDate
                  date, ShipmentNo varchar(10), PostingMode varchar(50).
   dbo.Supplier   (sql/09) SupplierKey char(6) PK, SupplierID, SupplierName.
                  Both POSUMMARY and ExpenseSummary join on SupplierID.
   dbo.Products   (sql/19, sql/23) ProductCode + BranchCode composite key,
                  Description.
   dbo.Branches   (ReportRepository.GetBranchesAsync) BranchCode, BranchName.

   ----------------------------------------------------------------------------
   DESIGN DECISIONS
   ----------------------------------------------------------------------------
   1. PERIOD = PO DateOrder. The price is agreed when the order is placed,
      and DateOrder is always populated. ReceivedDate uses a 1900-01-01
      sentinel on unreceived rows and is missing entirely on the DELIVERED
      migration batch (sql/19), so it is not used as the period date.
      Weekly buckets start on MONDAY, computed as days since 1900-01-01 (a
      Monday) mod 7, so the result does not depend on @@DATEFIRST.
      Date range: >= @DateFrom AND < DATEADD(DAY,1,@DateTo) (Hard Rule #4).

   2. QUANTITY = RECEIVED kg (PODETAILS.ActualQuantity), not ordered.
      (See PriceStatus in result set 1: NO PO LINES / NOT RECEIVED /
      INCOMPLETE rows are listed but never priced or averaged.) The
      pesos pay for what arrived. A shipment with linked invoices but 0
      received kg (not yet received) is still listed, with a NULL ₱/kg and
      PriceStatus = 'NOT RECEIVED', and is left out of every weighted
      average. It is never divided by the ordered quantity, which would
      make a price look better or worse than it was.

   3. WEIGHTED, NEVER AVERAGED: every supplier/period/product ₱/kg is
      SUM(amount) / SUM(kg), so a 27-tonne shipment outweighs a 500 kg
      one. An average of per-shipment rates would let a tiny trial order
      move a supplier's number as much as a full container does.

   4. SUPPLIER PRICE vs ADD-ON SPLIT. Each linked invoice is classified:
        CostRole = 'SUPPLIER'  when ExpenseSummary.SupplierID = the PO's
                               SupplierID (the meat supplier's own invoice
                               — the actual price offer);
        CostRole = 'ADD-ON'    otherwise (forwarder, broker, customs,
                               trucking, cold storage, and so on).
      This lets the client compare the supplier's price separately from
      the logistics add-ons, which a supplier doesn't control. HEURISTIC:
      if a supplier's invoice is booked under another SupplierID (an agent
      or importer of record), it lands in ADD-ON. The total landed cost is
      correct either way; only the split moves.

   5. INVOICE BASIS, STATED PLAINLY. ExpenseSummary.Amount is the full
      invoice amount: gross of EWT (correct — withholding doesn't reduce
      cost, Hard Rule #8) but it INCLUDES any recoverable input VAT and any
      invoice lines that were not capitalised to inventory. That is exactly
      the formula the client asked for, and it is the right basis for
      "what did this supplier's shipment cost us in cash". It is NOT the
      inventory-costed unit cost. sp_rpt_ItemCostingRecon_List's
      TotalInventoryCost / TotalCostIncorporated is that other basis; the
      web service shows both side by side per shipment rather than
      recomputing it here (that proc is ERP-owned, do not alter).

   6. MIXED-PRODUCT SHIPMENTS. PO lines have no cost, so a shipment's pesos
      cannot be split across its products. A PO with pork belly and pork
      shoulder gets ONE blended ₱/kg. So:
        - result set 2 (supplier x period) includes every priced shipment
          and reports how many were mixed, so the reader knows how much
          blending is in the number;
        - result set 3 (product x supplier x period) uses SINGLE-PRODUCT
          shipments ONLY — the only like-for-like price comparison this
          data can honestly support. Mixed shipments are never allocated by
          kg, because that assumes every cut costs the same per kilo.

   7. EXCLUSIONS: POSUMMARY.Status = 'CANCELLED'; ExpenseSummary rows whose
      Status contains CANCEL or VOID (VERIFY LIVE: the distinct Status
      values seen so far are UNPAID / FULLYPAID / POSTED, and no cancelled
      value has been confirmed yet); ExpenseSummary rows with a blank
      ShipmentNo (not linked to a PO — nothing to divide by).
      UNPOSTED invoices (blank PostingMode) are INCLUDED — an invoice not
      yet posted to GL is still the supplier's price — and counted per
      shipment in UnpostedExpenseCount so the reader can see it.

   8. READ-ONLY. SELECTs into #temp tables only. No base-table writes.

   ----------------------------------------------------------------------------
   PARAMETERS
   ----------------------------------------------------------------------------
   @DateFrom, @DateTo  date, required — PO DateOrder range, inclusive.
   @Period             char(1) = 'M' — 'W' weekly, 'M' monthly, 'Y' yearly.
   @SupplierIDs        varchar(max) = NULL — CSV of PO SupplierIDs; NULL=all.
   @BranchCodes        varchar(200) = NULL — CSV of receiving branch codes
                       (POSUMMARY.BranchCode, varchar, never int).
   @ProductCode        varchar(20) = NULL — only shipments that contain this
                       product (PODETAILS.OrderCode).

   RESULT SETS (order is part of the contract — the repository reads them in
   this order):
     1  Shipments      one row per PO with >= 1 linked invoice
     2  SupplierPeriod one row per (period, PO supplier), priced shipments
     3  ProductPeriod  one row per (period, product, supplier), single-
                       product priced shipments only
     4  Expenses       one row per linked invoice, with its CostRole
============================================================================ */

IF OBJECT_ID('dbo.sp_rpt_SupplierPriceComparison', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_SupplierPriceComparison;
GO

CREATE PROCEDURE dbo.sp_rpt_SupplierPriceComparison
    @DateFrom    date,
    @DateTo      date,
    @Period      char(1)      = 'M',
    @SupplierIDs varchar(max) = NULL,
    @BranchCodes varchar(200) = NULL,
    @ProductCode varchar(20)  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @DateFrom IS NULL OR @DateTo IS NULL
        THROW 50001, 'sp_rpt_SupplierPriceComparison: @DateFrom and @DateTo are required.', 1;

    IF @DateFrom > @DateTo
    BEGIN
        DECLARE @Swap date = @DateFrom;
        SET @DateFrom = @DateTo;
        SET @DateTo = @Swap;
    END;

    SET @Period = UPPER(ISNULL(NULLIF(LTRIM(RTRIM(@Period)), ''), 'M'));
    IF @Period NOT IN ('W', 'M', 'Y')
        THROW 50002, 'sp_rpt_SupplierPriceComparison: @Period must be W, M or Y.', 1;

    SET @ProductCode = NULLIF(LTRIM(RTRIM(@ProductCode)), '');

    DECLARE @From datetime = CAST(@DateFrom AS datetime);
    DECLARE @End  datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));

    /* ---- CSV filters -> temp tables (same convention as sp_rpt_Exec_*) ---- */
    CREATE TABLE #Branch (BranchCode varchar(5) PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(ISNULL(@BranchCodes, ''))), '') IS NOT NULL
        INSERT INTO #Branch (BranchCode)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@BranchCodes, ',')
        WHERE LTRIM(RTRIM(value)) <> '';
    DECLARE @FilterBranch bit = CASE WHEN EXISTS (SELECT 1 FROM #Branch) THEN 1 ELSE 0 END;

    CREATE TABLE #SupplierFilter (SupplierID varchar(30) PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(ISNULL(@SupplierIDs, ''))), '') IS NOT NULL
        INSERT INTO #SupplierFilter (SupplierID)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@SupplierIDs, ',')
        WHERE LTRIM(RTRIM(value)) <> '';
    DECLARE @FilterSupplier bit = CASE WHEN EXISTS (SELECT 1 FROM #SupplierFilter) THEN 1 ELSE 0 END;

    /* ---- 1. Shipments (POs) in scope ------------------------------------ */
    CREATE TABLE #Ship
    (
        ShipmentNo  varchar(10) NOT NULL PRIMARY KEY,
        BranchCode  varchar(5)  NOT NULL,
        SupplierID  varchar(30) NOT NULL,
        POStatus    varchar(20) NULL,
        DateOrder   datetime    NOT NULL,
        PeriodStart date        NOT NULL
    );

    INSERT INTO #Ship (ShipmentNo, BranchCode, SupplierID, POStatus, DateOrder, PeriodStart)
    SELECT
        ps.ShipmentNo,
        CAST(ps.BranchCode AS varchar(5)),
        LTRIM(RTRIM(ps.SupplierID)),
        ps.Status,
        ps.DateOrder,
        CASE @Period
            WHEN 'Y' THEN DATEFROMPARTS(YEAR(ps.DateOrder), 1, 1)
            WHEN 'M' THEN DATEFROMPARTS(YEAR(ps.DateOrder), MONTH(ps.DateOrder), 1)
            /* Monday-start week: 1900-01-01 was a Monday. */
            ELSE DATEADD(DAY,
                         -(DATEDIFF(DAY, CAST('19000101' AS date), CAST(ps.DateOrder AS date)) % 7),
                         CAST(ps.DateOrder AS date))
        END
    FROM dbo.POSUMMARY AS ps
    WHERE ps.DateOrder >= @From
      AND ps.DateOrder <  @End
      AND ISNULL(ps.Status, '') <> 'CANCELLED'
      AND (@FilterBranch = 0
           OR EXISTS (SELECT 1 FROM #Branch AS b WHERE b.BranchCode = CAST(ps.BranchCode AS varchar(5))))
      AND (@FilterSupplier = 0
           OR EXISTS (SELECT 1 FROM #SupplierFilter AS sf WHERE sf.SupplierID = LTRIM(RTRIM(ps.SupplierID))))
      /* Product filter keeps only shipments whose EVERY line is that
         product. A shipment that also carries other cuts would put their
         kilos and pesos under a product-filtered heading (review #5). */
      AND (@ProductCode IS NULL
           OR (EXISTS (SELECT 1 FROM dbo.PODETAILS AS pdx
                       WHERE pdx.ShipmentNo = ps.ShipmentNo
                         AND LTRIM(RTRIM(pdx.OrderCode)) = @ProductCode)
               AND NOT EXISTS (SELECT 1 FROM dbo.PODETAILS AS pdy
                               WHERE pdy.ShipmentNo = ps.ShipmentNo
                                 AND LTRIM(RTRIM(pdy.OrderCode)) <> @ProductCode)));

    /* ---- 2. PO lines per shipment/product -------------------------------- */
    CREATE TABLE #Line
    (
        ShipmentNo  varchar(10)   NOT NULL,
        ProductCode varchar(20)   NOT NULL,
        OrderedKg   decimal(18,3) NOT NULL,
        ReceivedKg  decimal(18,3) NOT NULL,
        PRIMARY KEY (ShipmentNo, ProductCode)
    );

    INSERT INTO #Line (ShipmentNo, ProductCode, OrderedKg, ReceivedKg)
    SELECT
        pd.ShipmentNo,
        LTRIM(RTRIM(pd.OrderCode)),
        SUM(CAST(ISNULL(pd.Quantity, 0)       AS decimal(18,3))),
        SUM(CAST(ISNULL(pd.ActualQuantity, 0) AS decimal(18,3)))
    FROM dbo.PODETAILS AS pd
    JOIN #Ship AS s ON s.ShipmentNo = pd.ShipmentNo
    GROUP BY pd.ShipmentNo, LTRIM(RTRIM(pd.OrderCode));

    /* ---- 3. Linked expense invoices -------------------------------------- */
    CREATE TABLE #Exp
    (
        ShipmentNo        varchar(10)   NOT NULL,
        ReferenceNumber   varchar(10)   NULL,
        InvoiceNo         varchar(150)  NULL,
        ExpenseSupplierID varchar(30)   NULL,
        ExpenseDate       date          NULL,
        Description       varchar(300)  NULL,
        ExpenseStatus     varchar(50)   NULL,
        IsPostedToGL      bit           NOT NULL,
        Amount            decimal(18,2) NOT NULL,
        CostRole          varchar(10)   NOT NULL
    );

    INSERT INTO #Exp (ShipmentNo, ReferenceNumber, InvoiceNo, ExpenseSupplierID, ExpenseDate,
                      Description, ExpenseStatus, IsPostedToGL, Amount, CostRole)
    SELECT
        s.ShipmentNo,
        e.ReferenceNumber,
        e.InvoiceNo,
        LTRIM(RTRIM(e.SupplierID)),
        e.ExpenseDate,
        e.Description,
        e.Status,
        CASE WHEN LTRIM(RTRIM(ISNULL(e.PostingMode, ''))) <> '' THEN 1 ELSE 0 END,
        CAST(ISNULL(e.Amount, 0) AS decimal(18,2)),
        CASE WHEN LTRIM(RTRIM(ISNULL(e.SupplierID, ''))) = s.SupplierID
             THEN 'SUPPLIER' ELSE 'ADD-ON' END
    FROM dbo.ExpenseSummary AS e
    JOIN #Ship AS s ON s.ShipmentNo = e.ShipmentNo
    WHERE LTRIM(RTRIM(ISNULL(e.ShipmentNo, ''))) <> ''
      AND UPPER(ISNULL(e.Status, '')) NOT LIKE '%CANCEL%'
      AND UPPER(ISNULL(e.Status, '')) NOT LIKE '%VOID%';

    /* ---- 4. One priced row per shipment ---------------------------------- */
    CREATE TABLE #ShipAgg
    (
        ShipmentNo            varchar(10)   NOT NULL PRIMARY KEY,
        OrderedKg             decimal(18,3) NOT NULL,
        ReceivedKg            decimal(18,3) NOT NULL,
        ProductCount          int           NOT NULL,
        SingleProductCode     varchar(20)   NULL,
        ExpenseCount          int           NOT NULL,
        UnpostedExpenseCount  int           NOT NULL,
        SupplierInvoiceAmount decimal(18,2) NOT NULL,
        AddOnAmount           decimal(18,2) NOT NULL,
        TotalLandedAmount     decimal(18,2) NOT NULL
    );

    INSERT INTO #ShipAgg
    SELECT
        s.ShipmentNo,
        ISNULL(l.OrderedKg, 0),
        ISNULL(l.ReceivedKg, 0),
        ISNULL(l.ProductCount, 0),
        CASE WHEN l.ProductCount = 1 THEN l.OneProduct END,
        x.ExpenseCount,
        x.UnpostedCount,
        x.SupplierAmt,
        x.AddOnAmt,
        x.TotalAmt
    FROM #Ship AS s
    JOIN
    (
        SELECT ShipmentNo,
               ExpenseCount  = COUNT(*),
               UnpostedCount = SUM(CASE WHEN IsPostedToGL = 0 THEN 1 ELSE 0 END),
               SupplierAmt   = SUM(CASE WHEN CostRole = 'SUPPLIER' THEN Amount ELSE 0 END),
               AddOnAmt      = SUM(CASE WHEN CostRole = 'ADD-ON'   THEN Amount ELSE 0 END),
               TotalAmt      = SUM(Amount)
        FROM #Exp
        GROUP BY ShipmentNo
    ) AS x ON x.ShipmentNo = s.ShipmentNo
    LEFT JOIN
    (
        /* Only lines that actually received something count toward the
           product mix of the priced quantity; a zero-received line on an
           otherwise received PO would falsely mark it "mixed". Falls back to
           ordered lines when nothing at all was received yet. */
        SELECT ShipmentNo,
               OrderedKg    = SUM(OrderedKg),
               ReceivedKg   = SUM(ReceivedKg),
               ProductCount = CASE WHEN SUM(ReceivedKg) > 0
                                   THEN SUM(CASE WHEN ReceivedKg > 0 THEN 1 ELSE 0 END)
                                   ELSE COUNT(*) END,
               OneProduct   = CASE WHEN SUM(ReceivedKg) > 0
                                   THEN MAX(CASE WHEN ReceivedKg > 0 THEN ProductCode END)
                                   ELSE MAX(ProductCode) END
        FROM #Line
        GROUP BY ShipmentNo
    ) AS l ON l.ShipmentNo = s.ShipmentNo;

    /* ======================================================================
       RESULT SET 1 — Shipments
    ====================================================================== */
    SELECT
        s.ShipmentNo,
        BranchCode   = s.BranchCode,
        BranchName   = ISNULL(br.BranchName, ''),
        SupplierID   = s.SupplierID,
        SupplierName = ISNULL(sup.SupplierName, s.SupplierID),
        POStatus     = ISNULL(s.POStatus, ''),
        s.DateOrder,
        s.PeriodStart,
        PeriodLabel  = CASE @Period
                           WHEN 'Y' THEN CAST(YEAR(s.PeriodStart) AS varchar(4))
                           WHEN 'M' THEN CONVERT(varchar(7), s.PeriodStart, 120)
                           ELSE 'Wk ' + CONVERT(varchar(10), s.PeriodStart, 120)
                       END,
        a.OrderedKg,
        a.ReceivedKg,
        a.ProductCount,
        ProductCode        = ISNULL(a.SingleProductCode, ''),
        ProductDescription = CASE WHEN a.ProductCount = 1 THEN ISNULL(prod.Description, a.SingleProductCode)
                                  WHEN a.ProductCount = 0 THEN '(no PO lines)'
                                  ELSE 'MIXED (' + CAST(a.ProductCount AS varchar(10)) + ' products)' END,
        IsMultiProduct     = CAST(CASE WHEN a.ProductCount > 1 THEN 1 ELSE 0 END AS bit),
        a.ExpenseCount,
        a.UnpostedExpenseCount,
        a.SupplierInvoiceAmount,
        a.AddOnAmount,
        a.TotalLandedAmount,
        SupplierPricePerKg = CAST(CASE WHEN a.ReceivedKg > 0 THEN a.SupplierInvoiceAmount / a.ReceivedKg END AS decimal(18,4)),
        AddOnPerKg         = CAST(CASE WHEN a.ReceivedKg > 0 THEN a.AddOnAmount / a.ReceivedKg END AS decimal(18,4)),
        LandedCostPerKg    = CAST(CASE WHEN a.ReceivedKg > 0 THEN a.TotalLandedAmount / a.ReceivedKg END AS decimal(18,4)),
        /* Order matters, first match wins:
             NO PO LINES   no PODETAILS rows at all (e.g. the DELIVERED
                           migration batch, sql/19) — nothing to divide by;
             NOT RECEIVED  PO lines exist but 0 kg received yet;
             INCOMPLETE    kilos received but NO invoice from the PO
                           supplier linked yet (only freight/broker so far,
                           or the supplier invoice is booked under another
                           SupplierID) — its ₱/kg would look far too cheap;
             PRICED        usable. Only PRICED rows enter result sets 2/3. */
        PriceStatus        = CASE WHEN a.ProductCount = 0          THEN 'NO PO LINES'
                                  WHEN a.ReceivedKg <= 0           THEN 'NOT RECEIVED'
                                  WHEN a.SupplierInvoiceAmount = 0 THEN 'INCOMPLETE'
                                  ELSE 'PRICED' END
    FROM #Ship AS s
    JOIN #ShipAgg AS a ON a.ShipmentNo = s.ShipmentNo
    OUTER APPLY (SELECT TOP (1) b.BranchName FROM dbo.Branches AS b
                 WHERE b.BranchCode = s.BranchCode) AS br
    OUTER APPLY (SELECT TOP (1) su.SupplierName FROM dbo.Supplier AS su
                 WHERE LTRIM(RTRIM(su.SupplierID)) = s.SupplierID
                 ORDER BY su.SupplierKey) AS sup
    OUTER APPLY (SELECT TOP (1) p.Description FROM dbo.Products AS p
                 WHERE p.ProductCode = a.SingleProductCode
                 ORDER BY CASE WHEN p.BranchCode = s.BranchCode THEN 0 ELSE 1 END) AS prod
    ORDER BY s.DateOrder DESC, s.ShipmentNo DESC;

    /* ======================================================================
       RESULT SET 2 — Supplier x Period (priced shipments only)
    ====================================================================== */
    ;WITH SP AS
    (
        SELECT
            s.PeriodStart,
            s.SupplierID,
            Shipments             = COUNT(*),
            MixedShipments        = SUM(CASE WHEN a.ProductCount > 1 THEN 1 ELSE 0 END),
            ReceivedKg            = SUM(a.ReceivedKg),
            SupplierInvoiceAmount = SUM(a.SupplierInvoiceAmount),
            AddOnAmount           = SUM(a.AddOnAmount),
            TotalLandedAmount     = SUM(a.TotalLandedAmount),
            MinShipmentPerKg      = MIN(a.TotalLandedAmount / NULLIF(a.ReceivedKg, 0)),
            MaxShipmentPerKg      = MAX(a.TotalLandedAmount / NULLIF(a.ReceivedKg, 0))
        FROM #Ship AS s
        JOIN #ShipAgg AS a ON a.ShipmentNo = s.ShipmentNo
        WHERE a.ReceivedKg > 0
          AND a.SupplierInvoiceAmount > 0          -- PRICED only, see PriceStatus
        GROUP BY s.PeriodStart, s.SupplierID
    ),
    SP2 AS
    (
        SELECT
            SP.*,
            LandedCostPerKg    = TotalLandedAmount / ReceivedKg,
            SupplierPricePerKg = SupplierInvoiceAmount / ReceivedKg,
            AddOnPerKg         = AddOnAmount / ReceivedKg,
            PeriodAvgPerKg     = SUM(TotalLandedAmount) OVER (PARTITION BY PeriodStart)
                                 / NULLIF(SUM(ReceivedKg) OVER (PARTITION BY PeriodStart), 0),
            SuppliersInPeriod  = COUNT(*) OVER (PARTITION BY PeriodStart),
            PrevPeriodStart    = LAG(PeriodStart) OVER (PARTITION BY SupplierID ORDER BY PeriodStart),
            PrevLandedPerKg    = LAG(TotalLandedAmount / ReceivedKg) OVER (PARTITION BY SupplierID ORDER BY PeriodStart)
        FROM SP
    )
    SELECT
        SP2.PeriodStart,
        PeriodLabel  = CASE @Period
                           WHEN 'Y' THEN CAST(YEAR(SP2.PeriodStart) AS varchar(4))
                           WHEN 'M' THEN CONVERT(varchar(7), SP2.PeriodStart, 120)
                           ELSE 'Wk ' + CONVERT(varchar(10), SP2.PeriodStart, 120)
                       END,
        SP2.SupplierID,
        SupplierName = ISNULL(sup.SupplierName, SP2.SupplierID),
        SP2.Shipments,
        SP2.MixedShipments,
        SP2.ReceivedKg,
        SP2.SupplierInvoiceAmount,
        SP2.AddOnAmount,
        SP2.TotalLandedAmount,
        LandedCostPerKg    = CAST(SP2.LandedCostPerKg    AS decimal(18,4)),
        SupplierPricePerKg = CAST(SP2.SupplierPricePerKg AS decimal(18,4)),
        AddOnPerKg         = CAST(SP2.AddOnPerKg         AS decimal(18,4)),
        MinShipmentPerKg   = CAST(SP2.MinShipmentPerKg   AS decimal(18,4)),
        MaxShipmentPerKg   = CAST(SP2.MaxShipmentPerKg   AS decimal(18,4)),
        PeriodAvgPerKg     = CAST(SP2.PeriodAvgPerKg     AS decimal(18,4)),
        VsPeriodAvgPct     = CAST(CASE WHEN SP2.PeriodAvgPerKg > 0
                                       THEN (SP2.LandedCostPerKg - SP2.PeriodAvgPerKg) * 100.0 / SP2.PeriodAvgPerKg END AS decimal(9,2)),
        RankInPeriod       = RANK() OVER (PARTITION BY SP2.PeriodStart ORDER BY SP2.LandedCostPerKg ASC),
        SP2.SuppliersInPeriod,
        /* Previous period in which THIS supplier had a priced shipment —
           not necessarily the adjacent calendar period. PrevPeriodStart is
           returned so the UI can say "vs Jul" instead of implying "vs last
           month" when the supplier skipped August. */
        SP2.PrevPeriodStart,
        PrevLandedPerKg    = CAST(SP2.PrevLandedPerKg AS decimal(18,4)),
        ChangePct          = CAST(CASE WHEN SP2.PrevLandedPerKg > 0
                                       THEN (SP2.LandedCostPerKg - SP2.PrevLandedPerKg) * 100.0 / SP2.PrevLandedPerKg END AS decimal(9,2))
    FROM SP2
    OUTER APPLY (SELECT TOP (1) su.SupplierName FROM dbo.Supplier AS su
                 WHERE LTRIM(RTRIM(su.SupplierID)) = SP2.SupplierID
                 ORDER BY su.SupplierKey) AS sup
    ORDER BY SP2.PeriodStart DESC, SP2.LandedCostPerKg ASC;

    /* ======================================================================
       RESULT SET 3 — Product x Supplier x Period
       SINGLE-PRODUCT priced shipments only (see design decision #6).
    ====================================================================== */
    ;WITH PP AS
    (
        SELECT
            s.PeriodStart,
            ProductCode           = a.SingleProductCode,
            s.SupplierID,
            Shipments             = COUNT(*),
            ReceivedKg            = SUM(a.ReceivedKg),
            SupplierInvoiceAmount = SUM(a.SupplierInvoiceAmount),
            AddOnAmount           = SUM(a.AddOnAmount),
            TotalLandedAmount     = SUM(a.TotalLandedAmount),
            AnyBranchCode         = MIN(s.BranchCode)
        FROM #Ship AS s
        JOIN #ShipAgg AS a ON a.ShipmentNo = s.ShipmentNo
        WHERE a.ReceivedKg > 0
          AND a.SupplierInvoiceAmount > 0          -- PRICED only, see PriceStatus
          AND a.ProductCount = 1
          AND a.SingleProductCode IS NOT NULL
        GROUP BY s.PeriodStart, a.SingleProductCode, s.SupplierID
    ),
    PP2 AS
    (
        SELECT
            PP.*,
            LandedCostPerKg    = TotalLandedAmount / ReceivedKg,
            SupplierPricePerKg = SupplierInvoiceAmount / ReceivedKg,
            BestPerKg          = MIN(TotalLandedAmount / ReceivedKg) OVER (PARTITION BY PeriodStart, ProductCode),
            SuppliersForProduct = COUNT(*) OVER (PARTITION BY PeriodStart, ProductCode),
            PrevPeriodStart    = LAG(PeriodStart) OVER (PARTITION BY ProductCode, SupplierID ORDER BY PeriodStart),
            PrevLandedPerKg    = LAG(TotalLandedAmount / ReceivedKg) OVER (PARTITION BY ProductCode, SupplierID ORDER BY PeriodStart)
        FROM PP
    )
    SELECT
        PP2.PeriodStart,
        PeriodLabel  = CASE @Period
                           WHEN 'Y' THEN CAST(YEAR(PP2.PeriodStart) AS varchar(4))
                           WHEN 'M' THEN CONVERT(varchar(7), PP2.PeriodStart, 120)
                           ELSE 'Wk ' + CONVERT(varchar(10), PP2.PeriodStart, 120)
                       END,
        PP2.ProductCode,
        ProductDescription = ISNULL(prod.Description, PP2.ProductCode),
        PP2.SupplierID,
        SupplierName = ISNULL(sup.SupplierName, PP2.SupplierID),
        PP2.Shipments,
        PP2.ReceivedKg,
        PP2.TotalLandedAmount,
        LandedCostPerKg    = CAST(PP2.LandedCostPerKg    AS decimal(18,4)),
        SupplierPricePerKg = CAST(PP2.SupplierPricePerKg AS decimal(18,4)),
        BestPerKg          = CAST(PP2.BestPerKg          AS decimal(18,4)),
        VsBestPct          = CAST(CASE WHEN PP2.BestPerKg > 0
                                       THEN (PP2.LandedCostPerKg - PP2.BestPerKg) * 100.0 / PP2.BestPerKg END AS decimal(9,2)),
        RankForProduct     = RANK() OVER (PARTITION BY PP2.PeriodStart, PP2.ProductCode ORDER BY PP2.LandedCostPerKg ASC),
        PP2.SuppliersForProduct,
        PP2.PrevPeriodStart,
        PrevLandedPerKg    = CAST(PP2.PrevLandedPerKg AS decimal(18,4)),
        ChangePct          = CAST(CASE WHEN PP2.PrevLandedPerKg > 0
                                       THEN (PP2.LandedCostPerKg - PP2.PrevLandedPerKg) * 100.0 / PP2.PrevLandedPerKg END AS decimal(9,2))
    FROM PP2
    OUTER APPLY (SELECT TOP (1) su.SupplierName FROM dbo.Supplier AS su
                 WHERE LTRIM(RTRIM(su.SupplierID)) = PP2.SupplierID
                 ORDER BY su.SupplierKey) AS sup
    OUTER APPLY (SELECT TOP (1) p.Description FROM dbo.Products AS p
                 WHERE p.ProductCode = PP2.ProductCode
                 ORDER BY CASE WHEN p.BranchCode = PP2.AnyBranchCode THEN 0 ELSE 1 END) AS prod
    ORDER BY PP2.PeriodStart DESC, ProductDescription, PP2.LandedCostPerKg ASC;

    /* ======================================================================
       RESULT SET 4 — Linked invoices (for the shipment drill-down)
    ====================================================================== */
    SELECT
        e.ShipmentNo,
        ReferenceNumber     = ISNULL(e.ReferenceNumber, ''),
        InvoiceNo           = ISNULL(e.InvoiceNo, ''),
        ExpenseSupplierID   = ISNULL(e.ExpenseSupplierID, ''),
        ExpenseSupplierName = ISNULL(sup.SupplierName, ISNULL(e.ExpenseSupplierID, '')),
        e.ExpenseDate,
        Description         = ISNULL(e.Description, ''),
        ExpenseStatus       = ISNULL(e.ExpenseStatus, ''),
        e.IsPostedToGL,
        e.Amount,
        e.CostRole
    FROM #Exp AS e
    OUTER APPLY (SELECT TOP (1) su.SupplierName FROM dbo.Supplier AS su
                 WHERE LTRIM(RTRIM(su.SupplierID)) = e.ExpenseSupplierID
                 ORDER BY su.SupplierKey) AS sup
    ORDER BY e.ShipmentNo DESC, e.CostRole DESC, e.ExpenseDate, e.ReferenceNumber;
END;
GO

GRANT EXECUTE ON dbo.sp_rpt_SupplierPriceComparison TO rpt_reader;
GO

/* ============================================================================
   SMOKE TESTS — run on COREX001 after applying. Record results here.
   ============================================================================

   -- A. Default monthly call over the whole year so far
   EXEC dbo.sp_rpt_SupplierPriceComparison
        @DateFrom = '2026-01-01', @DateTo = '2026-09-30', @Period = 'M';

   -- B. Weekly and yearly return the same shipments, only bucketed
   --    differently: result set 1 row count must match A's.
   EXEC dbo.sp_rpt_SupplierPriceComparison '2026-01-01', '2026-09-30', 'W';
   EXEC dbo.sp_rpt_SupplierPriceComparison '2026-01-01', '2026-09-30', 'Y';

   -- C. Tie-out: result set 2 TotalLandedAmount summed across all rows must
   --    equal result set 1 TotalLandedAmount summed over PriceStatus =
   --    'PRICED' rows. And result set 1 SUM(TotalLandedAmount) must equal:
   SELECT SUM(CAST(e.Amount AS decimal(18,2)))
   FROM dbo.ExpenseSummary AS e
   JOIN dbo.POSUMMARY AS ps ON ps.ShipmentNo = e.ShipmentNo
   WHERE ps.DateOrder >= '2026-01-01' AND ps.DateOrder < '2026-10-01'
     AND ISNULL(ps.Status,'') <> 'CANCELLED'
     AND UPPER(ISNULL(e.Status,'')) NOT LIKE '%CANCEL%'
     AND UPPER(ISNULL(e.Status,'')) NOT LIKE '%VOID%';

   -- D. Cross-check against the ERP recon (same DateOrder basis): per
   --    shipment, result set 1 TotalLandedAmount should equal
   --    sp_rpt_ItemCostingRecon_List's TotalInvoiceAmount. The web service
   --    flags any shipment where they differ (LinkCheck = 'DIFFERS').
   --    Handoff doc §8: shipment 10955, PROFOOD NETHERLANDS, 27,250 qty.
   EXEC dbo.sp_rpt_SupplierPriceComparison '2026-01-01', '2026-09-30', 'M';
   EXEC dbo.sp_rpt_ItemCostingRecon_List NULL, NULL, '10955', 1;

   -- E. Gross vs net (Hard Rule #8). If Amount were net of withholding,
   --    this gap would be ~1-2% of Amount on paid rows. Expect ~0.
   SELECT TOP (20) ReferenceNumber, Amount, Balance, AmountPaid, EWTWithheld,
          DiscountWithheld, OffsetWithheld,
          Gap = Amount - (Balance + AmountPaid + ISNULL(EWTWithheld,0)
                          + ISNULL(DiscountWithheld,0) + ISNULL(OffsetWithheld,0))
   FROM dbo.ExpenseSummary WHERE ShipmentNo <> '' AND AmountPaid > 0
   ORDER BY ABS(Amount - (Balance + AmountPaid + ISNULL(EWTWithheld,0)
                + ISNULL(DiscountWithheld,0) + ISNULL(OffsetWithheld,0))) DESC;

   -- F. Is the goods cost ever booked in trade AP (APAccounts) instead of
   --    ExpenseSummary? sql/19 saw APAccounts rows per ShipmentNo. If
   --    APAccounts carries nonzero goods amounts for these POs, this report
   --    is missing the goods cost and shows only add-ons (INCOMPLETE rows).

   VERIFY LIVE (could not be read in the authoring session):
   1. SELECT DISTINCT Status FROM dbo.ExpenseSummary — confirm which value(s)
      mean cancelled/voided and tighten the NOT LIKE filter to them.
   2. Does ExpenseSummary.ShipmentNo actually carry the PO number the recon
      proc links on? If the recon links through another table, result set 1
      will show fewer invoices than the recon's LinkedExpenseCount — the
      service's LinkCheck column makes that visible per shipment.
   3. Is the supplier's own product invoice booked under the PO's
      SupplierID? Check CostRole on a few known shipments; if it always
      lands in ADD-ON, the split needs a different rule (e.g. an expense-
      type or account code), and the total is unaffected.
   4. dbo.Branches.BranchCode type vs POSUMMARY.BranchCode char(3).
   5. Supplier discounts (DiscountWithheld) are NOT deducted: Amount is the
      invoice before any payment-time discount. Confirm with Accounting
      whether a discount taken should lower the landed cost.
============================================================================ */
