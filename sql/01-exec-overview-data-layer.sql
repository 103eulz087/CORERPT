/* ============================================================================
   CORE REPORTING PORTAL — PHASE 2, MODULE 1: EXECUTIVE OVERVIEW
   Data layer: indexes, account hierarchy, mnemonic map, reporting procedures.

   Run order:  SECTION 1 -> 2 -> 3 -> 4 -> 5
   Target:     SQL Server 2016+ (uses STRING_SPLIT)

   CONVENTIONS USED THROUGHOUT
   ---------------------------
   Posted rows      TicketMaster.Status IN ('POSTED','UPDATED')
   Date range       >= @DateFrom AND < DATEADD(DAY,1,@DateTo)
                    (never BETWEEN — TicketDate is datetime and a time
                     component would silently drop the final day)
   Postable rows    ChartOfAccounts.AccountType = 'D'
                    'S' accounts are summary/rollup only and must never
                    receive a posting
   Signed amount    Nature 'D' -> Debit - Credit
                    Nature 'C' -> Credit - Debit
                    so a normal balance is always positive
   Period logic     YearEndIndicator 'IS' -> movement within the date range
                    YearEndIndicator 'BS' -> cumulative from inception to @DateTo
   Branch codes     ALWAYS varchar. '001' is not 1. No implicit conversion
                    anywhere in this file or in the application layer.
============================================================================ */


/* ============================================================================
   SECTION 1 — INDEXES
   TicketDetails has no key and no index. Every dashboard tile scans it by
   date and account, so these two are the difference between sub-second and
   unusable. Apply to a restored copy first and re-time your posting SPs:
   the clustered index changes insert behaviour on a table your compound
   ticket posting writes to constantly.
============================================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_TicketDetails_Date_Branch_Account'
                 AND object_id = OBJECT_ID('dbo.TicketDetails'))
BEGIN
    CREATE CLUSTERED INDEX IX_TicketDetails_Date_Branch_Account
        ON dbo.TicketDetails (TicketDate, BranchCode, AccountCode);
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_TicketDetails_Account_Date'
                 AND object_id = OBJECT_ID('dbo.TicketDetails'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_TicketDetails_Account_Date
        ON dbo.TicketDetails (AccountCode, TicketDate)
        INCLUDE (BranchCode, Debit, Credit, TicketNumber, SupplementaryNumber);
END
GO

/* Master is joined on its full 4-part PK from every detail row. This index
   lets the status + date filter resolve without touching the clustered index. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_TicketMaster_Status_Date'
                 AND object_id = OBJECT_ID('dbo.TicketMaster'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_TicketMaster_Status_Date
        ON dbo.TicketMaster (Status, TicketDate)
        INCLUDE (BranchCode, TicketNumber, SupplementaryNumber, Mnemonic);
END
GO


/* ============================================================================
   SECTION 2 — ACCOUNT HIERARCHY

   The chart is 5 levels deep (0-4) and self-referencing through
   SummaryAccount. Detail accounts sit at different depths: 401 SALES-VAT
   EXEMPT is a level-1 detail account, while 101030101 A/R TRADE is level 4.
   So you cannot use LevelNumber to decide what is postable — AccountType
   does that.

   This view flattens the tree once so every report becomes a simple join
   instead of a recursive CTE repeated in a dozen procedures.
============================================================================ */

IF OBJECT_ID('dbo.vw_AccountTree', 'V') IS NOT NULL
    DROP VIEW dbo.vw_AccountTree;
GO

CREATE VIEW dbo.vw_AccountTree
AS
WITH Tree AS
(
    /* Anchor: every account, pointing at itself */
    SELECT
        coa.AccountCode,
        coa.Description,
        coa.AccountType,
        coa.LevelNumber,
        coa.YearEndIndicator,
        coa.Nature,
        coa.DueToFromIndicator,
        AncestorCode  = coa.AccountCode,
        Depth         = 0
    FROM dbo.ChartOfAccounts AS coa

    UNION ALL

    /* Walk up through SummaryAccount, collecting every ancestor */
    SELECT
        t.AccountCode,
        t.Description,
        t.AccountType,
        t.LevelNumber,
        t.YearEndIndicator,
        t.Nature,
        t.DueToFromIndicator,
        AncestorCode = p.AccountCode,
        Depth        = t.Depth + 1
    FROM Tree AS t
    INNER JOIN dbo.ChartOfAccounts AS child
        ON child.AccountCode = t.AncestorCode
    INNER JOIN dbo.ChartOfAccounts AS p
        ON p.AccountCode = NULLIF(child.SummaryAccount, 'NULL')
)
SELECT
    AccountCode,
    Description,
    AccountType,
    LevelNumber,
    YearEndIndicator,
    Nature,
    DueToFromIndicator,
    AncestorCode,
    Depth
FROM Tree;
GO

/*  Usage: every detail account under REVENUE (root '4')

    SELECT AccountCode FROM dbo.vw_AccountTree
    WHERE AncestorCode = '4' AND AccountType = 'D';

    Because the anchor row points at itself, an account is its own ancestor
    at Depth 0. That is deliberate: '401' rolls up under '4' AND matches a
    direct filter on '401' without a special case.
*/


/* ============================================================================
   SECTION 3 — MNEMONIC MAP

   TicketMaster.Mnemonic is the transaction-type discriminator. Hard-coding
   lists of mnemonics inside each report is how reports drift out of sync
   with each other, so it lives in a table instead. When you add a posting
   type to the ERP, add a row here and every dashboard picks it up.

   NOTE — 'PV-AP' and its variants appeared three times in your list with
   different descriptions (AP settlement, FX realized gain, FX realized
   loss). The mnemonic is the same; only the GL shape differs. Stored once
   here. If you ever need to separate FX effects, that has to come from the
   account codes on the ticket, not the mnemonic.
============================================================================ */

IF OBJECT_ID('dbo.RptMnemonicMap', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.RptMnemonicMap
    (
        Mnemonic     varchar(50)  NOT NULL PRIMARY KEY,
        Family       varchar(20)  NOT NULL,
        Description  varchar(200) NULL,
        /* Transfers and intercompany net to zero on a consolidated view but
           are real movements on a single-branch view. Reports that
           consolidate must exclude them. */
        IsInternal   bit          NOT NULL DEFAULT (0)
    );
END
GO

MERGE dbo.RptMnemonicMap AS tgt
USING (VALUES
    /* --- Sales -------------------------------------------------------- */
    ('SI-VAT',              'SALES',        'Sales Invoice - VATable + COGS', 0),
    ('SI-VATEX',            'SALES',        'Sales Invoice - VAT Exempt + COGS', 0),
    ('CR-CASH',             'SALES',        'Cash Sale - VAT Exempt + COGS', 0),
    ('CR-CASH-VAT',         'SALES',        'Cash Sale - VATable + COGS', 0),
    ('CR-CARD-VAT',         'SALES',        'Card Sale - VATable + COGS', 0),
    ('CR-CARD-VATEX',       'SALES',        'Card Sale - VAT Exempt + COGS', 0),

    /* --- Customer adjustments ----------------------------------------- */
    ('CM-CLIENT-VAT',       'SALES_ADJ',    'Client Credit Memo - VATable', 0),
    ('CM-CLIENT-VATEX',     'SALES_ADJ',    'Client Credit Memo - VAT Exempt', 0),
    ('DM-CLIENT-VAT',       'SALES_ADJ',    'Client Debit Memo - VATable', 0),
    ('DM-CLIENT-VATEX',     'SALES_ADJ',    'Client Debit Memo - VAT Exempt', 0),

    /* --- Collections --------------------------------------------------- */
    ('OR-COLL',             'COLLECTION',   'Collection - Official Receipt', 0),
    ('OR-COMPLETE',         'COLLECTION',   'Collection with client EWT, discount, overpayment', 0),
    ('OR-DISC',             'COLLECTION',   'Collection with sales discount', 0),
    ('OR-DISC-OFFSET',      'COLLECTION',   'Collection with discount and advance offset', 0),
    ('OR-DISC-OVERPAY',     'COLLECTION',   'Collection with discount and overpayment', 0),
    ('OR-EWT',              'COLLECTION',   'Collection with client EWT', 0),
    ('OR-EWT-DISC',         'COLLECTION',   'Collection with EWT and discount', 0),
    ('OR-EWT-DISC-OFFSET',  'COLLECTION',   'Collection with EWT, discount and advance offset', 0),
    ('OR-EWT-DISC-OVERPAY', 'COLLECTION',   'Collection with EWT, discount and overpayment', 0),
    ('OR-EWT-OFFSET',       'COLLECTION',   'Collection with EWT and advance offset', 0),
    ('OR-EWT-OVERPAY',      'COLLECTION',   'Collection with EWT and overpayment', 0),
    ('OR-OFFSET',           'COLLECTION',   'Collection with offset/advance', 0),
    ('OR-OVERPAY',          'COLLECTION',   'Collection with overpayment only', 0),

    /* --- Purchases ----------------------------------------------------- */
    ('PO-VAT',              'PURCHASE',     'Purchase Order - VATable goods receipt', 0),
    ('PO-VATEX',            'PURCHASE',     'Purchase Order - VAT Exempt goods receipt', 0),
    ('PO-RETALLOW',         'PURCHASE_ADJ', 'Purchase returns and allowances', 0),
    ('CM-SUP-VAT',          'PURCHASE_ADJ', 'Supplier Credit Memo - VATable', 0),
    ('CM-SUP-VATEX',        'PURCHASE_ADJ', 'Supplier Credit Memo - VAT Exempt', 0),
    ('DM-SUP-VAT',          'PURCHASE_ADJ', 'Supplier Debit Memo - VATable', 0),
    ('DM-SUP-VATEX',        'PURCHASE_ADJ', 'Supplier Debit Memo - VAT Exempt', 0),

    /* --- Supplier payments --------------------------------------------- */
    ('PV-AP',               'PAYMENT',      'Payment Voucher - AP settlement (cash / FX gain / FX loss)', 0),
    ('PV-AP-DISC',          'PAYMENT',      'Payment Voucher - AP with purchase discount', 0),
    ('PV-AP-EWT',           'PAYMENT',      'Payment Voucher - AP with EWT', 0),
    ('PV-AP-EWT-DISC',      'PAYMENT',      'Payment Voucher - AP with EWT and discount', 0),

    /* --- Expenses ------------------------------------------------------ */
    ('EXP-AP',              'EXPENSE',      'Expense recognition - direct, no VAT no EWT', 0),
    ('EXP-AP-EWT',          'EXPENSE',      'Expense recognition - with EWT, no VAT', 0),
    ('EXP-AP-VAT',          'EXPENSE',      'Expense recognition - with input VAT', 0),
    ('EXP-AP-VAT-EWT',      'EXPENSE',      'Expense recognition - with input VAT and EWT', 0),
    ('EXP-ACCRUAL',         'EXPENSE',      'Expense accrual - month end recognition', 0),
    ('EXP-ACCRUAL-PAY',     'PAYMENT',      'Payment of accrued expense', 0),
    ('EXP-ACCRUAL-PAY-EWT', 'PAYMENT',      'Payment of accrued expense with EWT', 0),
    ('EXP-AMORT',           'EXPENSE',      'Prepaid expense - monthly amortization', 0),
    ('EXP-BAD-DEBT',        'EXPENSE',      'Bad debt expense', 0),
    ('EXP-DEPR',            'DEPRECIATION', 'Depreciation expense', 0),
    ('EXP-DIRECT',          'EXPENSE',      'Direct expense - cash payment', 0),
    ('EXP-EWT',             'EXPENSE',      'Direct expense with EWT - cash payment', 0),
    ('EXP-MULTIBRANCH-BR',  'EXPENSE',      'Multi-branch expense - branch cost allocation', 0),
    ('EXP-MULTIBRANCH-HO',  'EXPENSE',      'Multi-branch expense - HO pays, HO books', 0),
    ('EXP-PAYROLL',         'EXPENSE',      'Payroll expense', 0),
    ('EXP-PAYROLL-GOV',     'EXPENSE',      'Payroll - government contributions', 0),
    ('EXP-PCF',             'EXPENSE',      'Petty cash fund - expense liquidation', 0),
    ('EXP-PCF-REPLEN',      'PAYMENT',      'Petty cash fund - replenishment', 0),
    ('EXP-PREPAID',         'EXPENSE',      'Prepaid expense - advance payment', 0),

    /* --- Depreciation schedules ---------------------------------------- */
    ('DEP-EQUIP',           'DEPRECIATION', 'Depreciation - warehouse and office equipment', 0),
    ('DEP-FURN',            'DEPRECIATION', 'Depreciation - furniture and fixtures', 0),
    ('DEP-LAND-IMPR',       'DEPRECIATION', 'Depreciation - land improvements', 0),
    ('DEP-LEASEHOLD',       'DEPRECIATION', 'Depreciation - leasehold improvements', 0),
    ('DEP-SOFTWARE',        'DEPRECIATION', 'Depreciation - software', 0),
    ('DEP-TOOLS',           'DEPRECIATION', 'Depreciation - tools and machinery', 0),
    ('DEP-TRANS',           'DEPRECIATION', 'Depreciation - transportation equipment', 0),

    /* --- Internal movement: excluded from consolidated figures ---------- */
    ('IT-HO-VAT',           'TRANSFER',     'Inventory transfer HO to branch - VAT (HO books)', 1),
    ('IT-HO-VATEX',         'TRANSFER',     'Inventory transfer HO to branch - VAT Exempt (HO books)', 1),
    ('IT-BR-VAT',           'TRANSFER',     'Inventory receipt from HO - VAT (branch books)', 1),
    ('IT-BR-VATEX',         'TRANSFER',     'Inventory receipt from HO - VAT Exempt (branch books)', 1),
    ('IT-BRA-VATEX',        'TRANSFER',     'Branch-to-branch transfer - VAT Exempt (sender)', 1),
    ('IT-BRB-VATEX',        'TRANSFER',     'Branch-to-branch transfer - VAT Exempt (receiver)', 1),
    ('JV-ICSETT',           'INTERCOMPANY', 'Intercompany settlement', 1),
    ('JV-ICSETT-EXP',       'INTERCOMPANY', 'Intercompany settlement - expense reimbursement', 1)
) AS src (Mnemonic, Family, Description, IsInternal)
ON tgt.Mnemonic = src.Mnemonic
WHEN MATCHED THEN
    UPDATE SET Family = src.Family, Description = src.Description, IsInternal = src.IsInternal
WHEN NOT MATCHED BY TARGET THEN
    INSERT (Mnemonic, Family, Description, IsInternal)
    VALUES (src.Mnemonic, src.Family, src.Description, src.IsInternal);
GO


/* ============================================================================
   SECTION 4 — REPORTING PROCEDURES

   All four take the same parameter shape so the application layer can build
   one filter object and pass it everywhere:

       @DateFrom    date
       @DateTo      date         inclusive
       @BranchCodes varchar(200) comma separated, NULL or '' = all branches
============================================================================ */

/* ----------------------------------------------------------------------------
   4.1  sp_rpt_Exec_Summary
   The six headline tiles, with prior-period comparatives for the deltas.
   One row out, one column per metric — the controller maps it straight
   onto the view model.
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.sp_rpt_Exec_Summary', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Exec_Summary;
GO

CREATE PROCEDURE dbo.sp_rpt_Exec_Summary
    @DateFrom    date,
    @DateTo      date,
    @BranchCodes varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End       datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @Start     datetime = CAST(@DateFrom AS datetime);

    /* Prior period = same number of days, immediately before @DateFrom */
    DECLARE @Days      int      = DATEDIFF(DAY, @DateFrom, @DateTo) + 1;
    DECLARE @PriorFrom datetime = DATEADD(DAY, -@Days, @Start);
    DECLARE @PriorEnd  datetime = @Start;

    /* Branch filter resolved once into a temp table.
       Empty table = no filter. */
    CREATE TABLE #Branch (BranchCode varchar(5) PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(ISNULL(@BranchCodes, ''))), '') IS NOT NULL
        INSERT INTO #Branch (BranchCode)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@BranchCodes, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @FilterBranch bit = CASE WHEN EXISTS (SELECT 1 FROM #Branch) THEN 1 ELSE 0 END;

    /* ---- Pull every posted detail line once, signed, tagged ------------- */
    CREATE TABLE #Line
    (
        AccountCode varchar(20)  NOT NULL,
        BranchCode  varchar(5)   NOT NULL,
        TicketDate  datetime     NOT NULL,
        Signed      money        NOT NULL,
        Book        char(2)      NOT NULL   -- 'IS' or 'BS'
    );

    INSERT INTO #Line (AccountCode, BranchCode, TicketDate, Signed, Book)
    SELECT
        td.AccountCode,
        td.BranchCode,
        td.TicketDate,
        Signed = CASE coa.Nature
                     WHEN 'D' THEN td.Debit  - td.Credit
                     ELSE          td.Credit - td.Debit
                 END,
        coa.YearEndIndicator
    FROM dbo.TicketDetails AS td
    INNER JOIN dbo.TicketMaster AS tm
        ON  tm.TicketDate          = td.TicketDate
        AND tm.SupplementaryNumber = td.SupplementaryNumber
        AND tm.BranchCode          = td.BranchCode
        AND tm.TicketNumber        = td.TicketNumber
    INNER JOIN dbo.ChartOfAccounts AS coa
        ON coa.AccountCode = td.AccountCode
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND coa.AccountType = 'D'
      AND td.TicketDate < @End           -- BS needs everything up to @DateTo
      AND (@FilterBranch = 0
           OR td.BranchCode IN (SELECT BranchCode FROM #Branch));

    /* ---- Income statement: movement inside the window ------------------- */
    DECLARE
        @NetSales      money = 0, @NetSalesPrior  money = 0,
        @COGS          money = 0, @COGSPrior      money = 0,
        @OpEx          money = 0, @OpExPrior      money = 0,
        @OtherIncome   money = 0;

    SELECT
        @NetSales     = SUM(CASE WHEN t.AncestorCode IN ('401','402','40103')
                                  AND l.TicketDate >= @Start THEN l.Signed END),
        @NetSalesPrior= SUM(CASE WHEN t.AncestorCode IN ('401','402','40103')
                                  AND l.TicketDate >= @PriorFrom
                                  AND l.TicketDate <  @PriorEnd THEN l.Signed END),
        @OtherIncome  = SUM(CASE WHEN t.AncestorCode IN ('403','404','405')
                                  AND l.TicketDate >= @Start THEN l.Signed END),
        @COGS         = SUM(CASE WHEN t.AncestorCode = '5'
                                  AND l.TicketDate >= @Start THEN l.Signed END),
        @COGSPrior    = SUM(CASE WHEN t.AncestorCode = '5'
                                  AND l.TicketDate >= @PriorFrom
                                  AND l.TicketDate <  @PriorEnd THEN l.Signed END),
        @OpEx         = SUM(CASE WHEN t.AncestorCode = '6'
                                  AND l.TicketDate >= @Start THEN l.Signed END),
        @OpExPrior    = SUM(CASE WHEN t.AncestorCode = '6'
                                  AND l.TicketDate >= @PriorFrom
                                  AND l.TicketDate <  @PriorEnd THEN l.Signed END)
    FROM #Line AS l
    INNER JOIN dbo.vw_AccountTree AS t
        ON t.AccountCode = l.AccountCode
    WHERE l.Book = 'IS';

    /* SALES DISCOUNT (40103) has Nature 'D' while its parent REVENUE is 'C',
       so its signed value is already negative against sales. Net Sales above
       is therefore net of discount with no extra subtraction. */

    /* ---- Balance sheet: cumulative to @DateTo --------------------------- */
    DECLARE
        @Cash        money = 0,
        @ARTrade     money = 0,
        @APTrade     money = 0,
        @InvOnHand   money = 0,
        @InvInTransit money = 0;

    SELECT
        @Cash         = SUM(CASE WHEN t.AncestorCode IN ('10101','10102')  THEN l.Signed END),
        @ARTrade      = SUM(CASE WHEN t.AncestorCode = '101030101'         THEN l.Signed END),
        @APTrade      = SUM(CASE WHEN t.AncestorCode IN ('20101','20102','20103') THEN l.Signed END),
        @InvOnHand    = SUM(CASE WHEN t.AncestorCode = '1010402'           THEN l.Signed END),
        @InvInTransit = SUM(CASE WHEN t.AncestorCode = '1010401'           THEN l.Signed END)
    FROM #Line AS l
    INNER JOIN dbo.vw_AccountTree AS t
        ON t.AccountCode = l.AccountCode
    WHERE l.Book = 'BS';

    SELECT
        AsOf              = SYSDATETIME(),
        DateFrom          = @DateFrom,
        DateTo            = @DateTo,
        NetSales          = ISNULL(@NetSales, 0),
        NetSalesPrior     = ISNULL(@NetSalesPrior, 0),
        OtherIncome       = ISNULL(@OtherIncome, 0),
        COGS              = ISNULL(@COGS, 0),
        COGSPrior         = ISNULL(@COGSPrior, 0),
        GrossProfit       = ISNULL(@NetSales, 0) - ISNULL(@COGS, 0),
        GrossMarginPct    = CASE WHEN ISNULL(@NetSales, 0) = 0 THEN NULL
                                 ELSE (ISNULL(@NetSales,0) - ISNULL(@COGS,0))
                                      * 100.0 / @NetSales END,
        GrossMarginPctPrior = CASE WHEN ISNULL(@NetSalesPrior, 0) = 0 THEN NULL
                                 ELSE (ISNULL(@NetSalesPrior,0) - ISNULL(@COGSPrior,0))
                                      * 100.0 / @NetSalesPrior END,
        OperatingExpense  = ISNULL(@OpEx, 0),
        OperatingExpensePrior = ISNULL(@OpExPrior, 0),
        NetIncome         = ISNULL(@NetSales,0) + ISNULL(@OtherIncome,0)
                            - ISNULL(@COGS,0) - ISNULL(@OpEx,0),
        CashPosition      = ISNULL(@Cash, 0),
        ReceivablesTrade  = ISNULL(@ARTrade, 0),
        PayablesTrade     = ISNULL(@APTrade, 0),
        InventoryOnHand   = ISNULL(@InvOnHand, 0),
        InventoryInTransit= ISNULL(@InvInTransit, 0);

    DROP TABLE #Line;
    DROP TABLE #Branch;
END
GO


/* ----------------------------------------------------------------------------
   4.2  sp_rpt_Exec_SalesTrend
   Monthly sales, COGS and margin for the trend chart. @MonthsBack counts
   back from the month containing @DateTo.
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.sp_rpt_Exec_SalesTrend', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Exec_SalesTrend;
GO

CREATE PROCEDURE dbo.sp_rpt_Exec_SalesTrend
    @DateTo      date,
    @MonthsBack  int = 13,
    @BranchCodes varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    /* First day of the earliest month in range */
    DECLARE @Start datetime = DATEADD(MONTH, DATEDIFF(MONTH, 0, @DateTo) - (@MonthsBack - 1), 0);

    ;WITH Filtered AS
    (
        SELECT
            MonthStart = DATEADD(MONTH, DATEDIFF(MONTH, 0, td.TicketDate), 0),
            Root       = CASE WHEN t.AncestorCode IN ('401','402','40103') THEN 'SALES'
                              WHEN t.AncestorCode = '5'                    THEN 'COGS' END,
            Signed     = CASE coa.Nature
                             WHEN 'D' THEN td.Debit  - td.Credit
                             ELSE          td.Credit - td.Debit
                         END
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        INNER JOIN dbo.ChartOfAccounts AS coa
            ON coa.AccountCode = td.AccountCode
        INNER JOIN dbo.vw_AccountTree AS t
            ON t.AccountCode = td.AccountCode
        WHERE tm.Status IN ('POSTED', 'UPDATED')
          AND coa.AccountType = 'D'
          AND td.TicketDate >= @Start
          AND td.TicketDate <  @End
          AND t.AncestorCode IN ('401','402','40103','5')
          AND (NULLIF(LTRIM(RTRIM(ISNULL(@BranchCodes,''))),'') IS NULL
               OR td.BranchCode IN (SELECT LTRIM(RTRIM(value))
                                    FROM STRING_SPLIT(@BranchCodes, ',')))
    )
    SELECT
        MonthStart,
        MonthLabel  = FORMAT(MonthStart, 'MMM yyyy'),
        NetSales    = ISNULL(SUM(CASE WHEN Root = 'SALES' THEN Signed END), 0),
        COGS        = ISNULL(SUM(CASE WHEN Root = 'COGS'  THEN Signed END), 0),
        GrossProfit = ISNULL(SUM(CASE WHEN Root = 'SALES' THEN Signed END), 0)
                    - ISNULL(SUM(CASE WHEN Root = 'COGS'  THEN Signed END), 0),
        GrossMarginPct = CASE WHEN ISNULL(SUM(CASE WHEN Root='SALES' THEN Signed END),0) = 0
                              THEN NULL
                              ELSE (ISNULL(SUM(CASE WHEN Root='SALES' THEN Signed END),0)
                                  - ISNULL(SUM(CASE WHEN Root='COGS'  THEN Signed END),0))
                                   * 100.0 / SUM(CASE WHEN Root='SALES' THEN Signed END) END
    FROM Filtered
    GROUP BY MonthStart
    ORDER BY MonthStart;
END
GO


/* ----------------------------------------------------------------------------
   4.3  sp_rpt_Exec_BranchScorecard
   One row per branch. Drives the branch contribution bars and the
   drill-down grid behind them.

   Internal movements (IT-*, JV-ICSETT*) are excluded — a stock transfer
   from HO to a branch is not revenue for either of them.
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.sp_rpt_Exec_BranchScorecard', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Exec_BranchScorecard;
GO

CREATE PROCEDURE dbo.sp_rpt_Exec_BranchScorecard
    @DateFrom date,
    @DateTo   date
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @Start datetime = CAST(@DateFrom AS datetime);

    ;WITH Movement AS
    (
        SELECT
            td.BranchCode,
            Bucket = CASE WHEN t.AncestorCode IN ('401','402','40103') THEN 'SALES'
                          WHEN t.AncestorCode = '5'                    THEN 'COGS'
                          WHEN t.AncestorCode = '6'                    THEN 'OPEX' END,
            Signed = CASE coa.Nature
                         WHEN 'D' THEN td.Debit  - td.Credit
                         ELSE          td.Credit - td.Debit
                     END
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        LEFT JOIN dbo.RptMnemonicMap AS mm
            ON mm.Mnemonic = tm.Mnemonic
        INNER JOIN dbo.ChartOfAccounts AS coa
            ON coa.AccountCode = td.AccountCode
        INNER JOIN dbo.vw_AccountTree AS t
            ON t.AccountCode = td.AccountCode
        WHERE tm.Status IN ('POSTED', 'UPDATED')
          AND coa.AccountType = 'D'
          AND coa.YearEndIndicator = 'IS'
          AND td.TicketDate >= @Start
          AND td.TicketDate <  @End
          AND ISNULL(mm.IsInternal, 0) = 0
          AND t.AncestorCode IN ('401','402','40103','5','6')
    ),
    /* Balance sheet figures are cumulative, so they need their own scan */
    Position AS
    (
        SELECT
            td.BranchCode,
            Receivables = SUM(CASE WHEN t.AncestorCode = '101030101'
                                   THEN td.Debit - td.Credit END),
            Inventory   = SUM(CASE WHEN t.AncestorCode IN ('1010401','1010402')
                                   THEN td.Debit - td.Credit END),
            Payables    = SUM(CASE WHEN t.AncestorCode IN ('20101','20102','20103')
                                   THEN td.Credit - td.Debit END)
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        INNER JOIN dbo.ChartOfAccounts AS coa
            ON coa.AccountCode = td.AccountCode
        INNER JOIN dbo.vw_AccountTree AS t
            ON t.AccountCode = td.AccountCode
        WHERE tm.Status IN ('POSTED', 'UPDATED')
          AND coa.AccountType = 'D'
          AND td.TicketDate < @End
          AND t.AncestorCode IN ('101030101','1010401','1010402','20101','20102','20103')
        GROUP BY td.BranchCode
    )
    SELECT
        b.BranchCode,
        b.BranchName,
        DisplayText = b.BranchCode + '-' + b.BranchName,
        NetSales    = ISNULL(SUM(CASE WHEN m.Bucket = 'SALES' THEN m.Signed END), 0),
        COGS        = ISNULL(SUM(CASE WHEN m.Bucket = 'COGS'  THEN m.Signed END), 0),
        OperatingExpense = ISNULL(SUM(CASE WHEN m.Bucket = 'OPEX' THEN m.Signed END), 0),
        GrossProfit = ISNULL(SUM(CASE WHEN m.Bucket = 'SALES' THEN m.Signed END), 0)
                    - ISNULL(SUM(CASE WHEN m.Bucket = 'COGS'  THEN m.Signed END), 0),
        GrossMarginPct = CASE WHEN ISNULL(SUM(CASE WHEN m.Bucket='SALES' THEN m.Signed END),0) = 0
                              THEN NULL
                              ELSE (ISNULL(SUM(CASE WHEN m.Bucket='SALES' THEN m.Signed END),0)
                                  - ISNULL(SUM(CASE WHEN m.Bucket='COGS'  THEN m.Signed END),0))
                                   * 100.0 / SUM(CASE WHEN m.Bucket='SALES' THEN m.Signed END) END,
        Receivables = ISNULL(MAX(p.Receivables), 0),
        Inventory   = ISNULL(MAX(p.Inventory), 0),
        Payables    = ISNULL(MAX(p.Payables), 0)
    FROM dbo.Branches AS b
    LEFT JOIN Movement AS m ON m.BranchCode = b.BranchCode
    LEFT JOIN Position AS p ON p.BranchCode = b.BranchCode
    GROUP BY b.BranchCode, b.BranchName
    ORDER BY NetSales DESC;
END
GO


/* ----------------------------------------------------------------------------
   4.4  sp_rpt_Exec_FlowBar
   The pipeline strip at the top of the executive board.

   IMPORTANT — only four of the six stages can be derived from the general
   ledger. 'Open POs' and 'Open Orders' are commitments that have not hit
   the GL yet, so they need the purchasing and sales order tables. Those two
   stages return NULL until you send me those schemas.
---------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.sp_rpt_Exec_FlowBar', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Exec_FlowBar;
GO

CREATE PROCEDURE dbo.sp_rpt_Exec_FlowBar
    @DateTo      date,
    @BranchCodes varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));

    ;WITH Bal AS
    (
        SELECT
            Node = CASE WHEN t.AncestorCode = '1010401'  THEN 'IN_TRANSIT'
                        WHEN t.AncestorCode = '1010402'  THEN 'ON_HAND'
                        WHEN t.AncestorCode = '101030101' THEN 'RECEIVABLES'
                        WHEN t.AncestorCode IN ('20101','20102','20103') THEN 'PAYABLES' END,
            Signed = CASE coa.Nature
                         WHEN 'D' THEN td.Debit  - td.Credit
                         ELSE          td.Credit - td.Debit
                     END
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        INNER JOIN dbo.ChartOfAccounts AS coa
            ON coa.AccountCode = td.AccountCode
        INNER JOIN dbo.vw_AccountTree AS t
            ON t.AccountCode = td.AccountCode
        WHERE tm.Status IN ('POSTED', 'UPDATED')
          AND coa.AccountType = 'D'
          AND td.TicketDate < @End
          AND t.AncestorCode IN ('1010401','1010402','101030101','20101','20102','20103')
          AND (NULLIF(LTRIM(RTRIM(ISNULL(@BranchCodes,''))),'') IS NULL
               OR td.BranchCode IN (SELECT LTRIM(RTRIM(value))
                                    FROM STRING_SPLIT(@BranchCodes, ',')))
    )
    SELECT
        StageOrder  = CAST(v.StageOrder AS int),
        StageKey    = v.StageKey,
        StageLabel  = v.StageLabel,
        /* money keeps the reader on GetDecimal. NULL for unavailable stages
           so the app renders them as pending, never as a zero balance. */
        Amount      = CASE WHEN v.FromGL = 1
                           THEN CAST(ISNULL((SELECT SUM(Signed) FROM Bal
                                             WHERE Node = v.StageKey), 0) AS money)
                           END,
        IsAvailable = CAST(v.FromGL AS int)
    FROM (VALUES
        (1, 'OPEN_PO',     'Open POs',           0),
        (2, 'IN_TRANSIT',  'In transit',         1),
        (3, 'ON_HAND',     'On hand',            1),
        (4, 'OPEN_ORDER',  'Open orders',        0),
        (5, 'RECEIVABLES', 'Receivables',        1),
        (6, 'PAYABLES',    'Payables',           1)
    ) AS v (StageOrder, StageKey, StageLabel, FromGL)
    ORDER BY v.StageOrder;
END
GO


/* ============================================================================
   SECTION 5 — HEALTH CHECK

   Run this before you trust any number above. It answers four questions
   that would each silently corrupt every dashboard tile. It also becomes
   the first widget on the Audit board later, so it earns its place twice.
============================================================================ */

IF OBJECT_ID('dbo.sp_rpt_DataHealthCheck', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_DataHealthCheck;
GO

CREATE PROCEDURE dbo.sp_rpt_DataHealthCheck
    @DateFrom date,
    @DateTo   date
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @Start datetime = CAST(@DateFrom AS datetime);

    /* 1. Tickets whose debits do not equal their credits */
    SELECT CheckName = 'Unbalanced tickets',
           Severity  = 'CRITICAL',
           Findings  = COUNT(*)
    FROM (
        SELECT td.TicketDate, td.SupplementaryNumber, td.BranchCode, td.TicketNumber
        FROM dbo.TicketDetails AS td
        INNER JOIN dbo.TicketMaster AS tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE tm.Status IN ('POSTED','UPDATED')
          AND td.TicketDate >= @Start AND td.TicketDate < @End
        GROUP BY td.TicketDate, td.SupplementaryNumber, td.BranchCode, td.TicketNumber
        HAVING SUM(td.Debit) <> SUM(td.Credit)
    ) AS x

    UNION ALL

    /* 2. Detail rows with no matching master — invisible to every report */
    SELECT 'Orphan detail rows', 'CRITICAL', COUNT(*)
    FROM dbo.TicketDetails AS td
    WHERE td.TicketDate >= @Start AND td.TicketDate < @End
      AND NOT EXISTS (
            SELECT 1 FROM dbo.TicketMaster AS tm
            WHERE tm.TicketDate          = td.TicketDate
              AND tm.SupplementaryNumber = td.SupplementaryNumber
              AND tm.BranchCode          = td.BranchCode
              AND tm.TicketNumber        = td.TicketNumber)

    UNION ALL

    /* 3. Postings to summary accounts — these break every rollup */
    SELECT 'Postings to summary accounts', 'CRITICAL', COUNT(*)
    FROM dbo.TicketDetails AS td
    INNER JOIN dbo.ChartOfAccounts AS coa ON coa.AccountCode = td.AccountCode
    WHERE td.TicketDate >= @Start AND td.TicketDate < @End
      AND coa.AccountType = 'S'

    UNION ALL

    /* 4. Postings to account codes that are not in the chart at all */
    SELECT 'Unknown account codes', 'CRITICAL', COUNT(*)
    FROM dbo.TicketDetails AS td
    WHERE td.TicketDate >= @Start AND td.TicketDate < @End
      AND NOT EXISTS (SELECT 1 FROM dbo.ChartOfAccounts AS coa
                      WHERE coa.AccountCode = td.AccountCode)

    UNION ALL

    /* 5. Mnemonics the reporting layer does not recognise — these fall
          through every classification and quietly understate totals */
    SELECT 'Unmapped mnemonics', 'WARNING', COUNT(DISTINCT tm.Mnemonic)
    FROM dbo.TicketMaster AS tm
    WHERE tm.TicketDate >= @Start AND tm.TicketDate < @End
      AND tm.Status IN ('POSTED','UPDATED')
      AND tm.Mnemonic IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.RptMnemonicMap AS mm
                      WHERE mm.Mnemonic = tm.Mnemonic)

    UNION ALL

    /* 6. Branch codes on tickets that do not exist in the branch master */
    SELECT 'Unknown branch codes', 'WARNING', COUNT(DISTINCT td.BranchCode)
    FROM dbo.TicketDetails AS td
    WHERE td.TicketDate >= @Start AND td.TicketDate < @End
      AND NOT EXISTS (SELECT 1 FROM dbo.Branches AS b
                      WHERE b.BranchCode = td.BranchCode);
END
GO


/* ============================================================================
   SMOKE TEST
============================================================================ */
/*
EXEC dbo.sp_rpt_DataHealthCheck      @DateFrom = '2026-07-01', @DateTo = '2026-07-24';
EXEC dbo.sp_rpt_Exec_Summary         @DateFrom = '2026-07-01', @DateTo = '2026-07-24';
EXEC dbo.sp_rpt_Exec_Summary         @DateFrom = '2026-07-01', @DateTo = '2026-07-24', @BranchCodes = '888,001';
EXEC dbo.sp_rpt_Exec_SalesTrend      @DateTo   = '2026-07-24', @MonthsBack = 13;
EXEC dbo.sp_rpt_Exec_BranchScorecard @DateFrom = '2026-07-01', @DateTo = '2026-07-24';
EXEC dbo.sp_rpt_Exec_FlowBar         @DateTo   = '2026-07-24';
*/
