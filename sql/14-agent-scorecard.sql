/* ============================================================================
   CORE REPORTING PORTAL — SALES MODULE: SALES AGENT SCORECARD
   Target:     CORECSERP_002_DEV (compat level 160, per 04-dev-compat-level-160.sql)
   New object. Nothing to alter/rename — dbo.sp_rpt_Agent_Scorecard does not
   exist yet in DEV (confirmed via OBJECT_ID before writing).

   Brief:      docs/brief-agent-scorecard.md
   Prior investigation trusted per task instructions (re-verified live against
   CORECSERP_002_DEV on 2026-09-23 via INFORMATION_SCHEMA.COLUMNS before
   writing anything below — every column name below was read from the real
   schema, not assumed):

     Customers                CustomerKey      char(8)      NOT NULL, PK
                               CustomerName     varchar(150)
                               AccountOfficer   varchar(50)  NULL  <- free-text
                                                agent display name, NO FK to
                                                AccountOfficers. 28 of 10,512
                                                customers have NULL/blank
                                                AccountOfficer today.
                               BranchCode       varchar(100) NULL  <- customer's
                                                HOME branch. NOT used anywhere
                                                in this proc (see note below).
                               CustomerCreditLimit money, Term float

     AccountOfficers           AccountID          varchar(15)
                                AccountOfficerName varchar(50)
                                SalesQuota         decimal      <- mostly NULL.
                                Per developer decision, LEFT ALONE — this proc
                                does not read or populate SalesQuota, and does
                                not add a QuotaAmount/AttainmentPct placeholder
                                column. That slot belongs in the DTO layer
                                later (backend-dev), not the SP result set, so
                                a schema-breaking ALTER isn't needed to add it.
                                Join to Customers is
                                Customers.AccountOfficer = AccountOfficerName
                                (NAME-to-NAME). AccountID is an unrelated
                                text-digit code — confirmed again live today:
                                every one of the 9 distinct non-blank
                                Customers.AccountOfficer values matches an
                                AccountOfficerName exactly; AccountID plays no
                                part in this proc.

     TransactionChargeSales    CustomerKey      char(8)       NOT NULL
                                BranchCode       char(3)       NOT NULL <- the
                                                 SELLING branch. NOT used here
                                                 either (see note below) — do
                                                 not confuse with Customers.
                                                 BranchCode (varchar(100),
                                                 HOME branch); the two are a
                                                 different axis and, per
                                                 05-accounting-aging.sql's
                                                 investigation, disagree often.
                                                 Hard Rule #2 applies to both:
                                                 never converted to int, never
                                                 conflated with each other
                                                 without an explicit CAST.
                                TransactionDate  date          NOT NULL <- true
                                                 DATE, no time component.
                                ReferenceNo      varchar(20)   NOT NULL
                                Balance          decimal       NOT NULL <- open
                                                 amount, already net.

     TicketMaster / TicketDetails / RptMnemonicMap / ChartOfAccounts /
     vw_AccountTree — same shapes already documented in
     01-exec-overview-data-layer.sql and 05-accounting-aging.sql. Re-read live
     today, unchanged.

   WHY THIS PROC NEVER TOUCHES BranchCode
   ----------------------------------------------------------------------------
   A sales agent's assigned customers are not confined to one branch (a
   Head-Office agent, for instance, can carry accounts homed at several
   branches). The scorecard is a per-AGENT rollup across the agent's entire
   book, company-wide. There is therefore no branch dimension in this proc's
   output at all. If a future branch-scoped drilldown is wanted, remember
   Customers.BranchCode (home branch, varchar(100)) and TransactionChargeSales.
   BranchCode (selling branch, char(3)) are different axes — do not join them
   to each other without an explicit CAST and a decision about which axis is
   meant (Hard Rule #2).

   THE ATTRIBUTION BRIDGE (agent-attributed NET SALES only; AR/activity/new-
   account metrics below join CustomerKey directly and do not need this bridge)
   ----------------------------------------------------------------------------
   No customer reference exists on TicketMaster/TicketDetails (the GL tables
   net sales is classified from via vw_AccountTree + RptMnemonicMap). The only
   verified bridge from a GL revenue posting to a customer (and therefore to
   an agent) is:

       TicketMaster.ReferenceNumber = TransactionChargeSales.ReferenceNo
       -> TransactionChargeSales.CustomerKey -> Customers.CustomerKey
       -> Customers.AccountOfficer

   This is NOT FK-enforced — an observed convention only. Verified live before
   coding (revenue postings = coa.AccountType='D', vw_AccountTree.AncestorCode
   IN ('401','402','40103'), posted rows only, IsInternal excluded):

     - No fan-out risk: every TicketMaster.ReferenceNumber used by a revenue
       posting matches AT MOST ONE TransactionChargeSales.ReferenceNo (checked
       live: 2,103 of 2,105 revenue ticket-rows matched exactly 1 row; the
       INNER JOIN below cannot multiply GL amounts).
     - Mnemonics currently posting to 401/402/40103 in DEV today: SI-VAT (95
       rows), SI-VATEX (1,982 rows), CM-CLIENT-VATEX (26 rows) — all 100%
       matched by the bridge, as the prior investigation stated — PLUS two
       mnemonics the prior investigation did NOT call out: OR-DISC (1 row) and
       OR-EWT-DISC (1 row), contra-revenue discount/EWT postings to 40103.
       **Both of those 2 rows are UNMATCHED by the bridge** (verified live,
       2026-09-23: ReferenceNumbers 17564 and 17528 have no corresponding
       TransactionChargeSales.ReferenceNo). Dollar impact today is small
       (₱1.17 + ₱21.00 = ₱22.17 over a 53-day sample window,
       2026-08-01..2026-09-22) but it is a REAL, CONFIRMED gap, not a
       theoretical one like the cash-sale mnemonics below:
         BridgeNetSales (this proc's method) = 40,462,823.55
         TotalNetSales  (sp_rpt_Exec_Summary's method, same window)
                                              = 40,462,845.72
         Gap                                  =         22.17
     - CR-CASH, CR-CASH-VAT, CR-CARD-VAT, CR-CARD-VATEX: confirmed 0 rows in
       DEV today (re-verified live). Untested by the bridge. If/when cash
       sales start posting, agent-attributed net sales in this proc could
       silently miss them (no ReferenceNumber match), while
       sp_rpt_Exec_Summary's company-wide net sales would still include them
       correctly.
     - NET EFFECT: this proc's SUM of every agent+UNASSIGNED row's NetSales /
       NetSales90Day will normally run very slightly LOW versus
       sp_rpt_Exec_Summary's / sp_rpt_AR_Aging's company-wide net-sales
       figures for the same window, by however much GL revenue activity
       fails to bridge to a TransactionChargeSales row. This is a KNOWN,
       DISCLOSED limitation — do not mistake agent-summed net sales for a
       guaranteed match to the company total. AR OUTSTANDING (see below) has
       no such gap, because it never uses this bridge at all.

   ATTRIBUTION MODEL (developer-confirmed, v1 semantics, not a bug)
   ----------------------------------------------------------------------------
   Current agent, all-time: Customers.AccountOfficer's value RIGHT NOW gets
   credit for that customer's entire sales/AR history in this proc — including
   NetSalesPrior (the prior-period comparative) and AR aging on invoices that
   predate the current assignment. No historical reassignment tracking exists
   anywhere in this database (no audit table, no timestamp column; the one
   Customers trigger only fires on INSERT). This is accepted v1 behavior.

   UNASSIGNED AND TOTAL ROWS (developer-confirmed)
   ----------------------------------------------------------------------------
   Every customer maps to an AgentLabel: Customers.AccountOfficer trimmed, or
   the literal 'UNASSIGNED' when NULL/blank. One real customer today,
   CustomerKey 00009505 (FORNIS, NInO & NEIL CALAGOS, home branch 888), has
   NULL AccountOfficer and ₱1,063,941.18 of open AR (confirmed live, matches
   exactly) — it surfaces as part of the UNASSIGNED row, never dropped.
   CustomerKeys present in TransactionChargeSales but with NO matching
   Customers row at all (orphans) are ALSO folded into UNASSIGNED, for the
   same never-silently-drop reason (0 such rows in DEV today, per
   05-accounting-aging.sql's investigation — a theoretical bucket for now,
   handled the same way as the AP unknown-supplier gap in that file).
   A company-wide TOTAL row is always included too, same convention as
   sp_rpt_AR_Aging's branch-rollup result set.

   FILTER SCOPE — @AgentNames only restricts which named-AGENT rows are
   returned. The UNASSIGNED row and the TOTAL row are ALWAYS computed over the
   FULL, unfiltered customer universe, regardless of @AgentNames — same
   deliberate-scope pattern as sp_rpt_AR_Aging's DSO result set staying
   company-wide regardless of @BranchCodes. This is what makes the tie-out
   requirement possible: SUM(every row's AROutstanding, unfiltered) must equal
   sp_rpt_AR_Aging's company-wide TotalOutstanding — verified below.

   PARAMETER NAMING — the brief's shape used "@AgentCodes", but the only key
   that exists is Customers.AccountOfficer, a free-text NAME with no code. The
   parameter here is named @AgentNames instead, to avoid implying a lookup key
   that does not exist. Same CSV-of-values, NULL/empty = all agents pattern as
   every other @...Codes filter in this repo (STRING_SPLIT, LTRIM/RTRIM).

   AR AGING — REUSES sp_rpt_AR_Aging's EXACT BUCKET DEFINITIONS, NOT
   REINVENTED: AgeDays = DATEDIFF(DAY, TransactionDate, @DateTo), open items
   only (Balance > 0), buckets Current(<=0) / 1-30 / 31-60 / 61-90 / 90+.
   "Past due 31+" = 31-60 + 61-90 + 90+ (AgeDays > 30). No NULL/future-date
   guard is applied here either, mirroring sp_rpt_AR_Aging exactly (that
   surfaces via sp_rpt_DataHealthCheck checks #8/#10, not here). Because this
   AR calculation reads TransactionChargeSales.Balance directly — the SAME
   base table sp_rpt_AR_Aging reads, with NO bridge/GL join involved — the
   sum of every row's AROutstanding here ties EXACTLY to sp_rpt_AR_Aging's
   company-wide TotalOutstanding for the same @DateTo. Verified below.

   AGENT-SCOPED DSO — same formula as sp_rpt_AR_Aging's company DSO
   (AROutstanding / trailing-90-day net sales * 90, NULL-guarded), re-scoped
   to each agent's own book. The net-sales leg necessarily uses the bridge
   above (it is the only path from GL revenue to an agent). Consequently:
     - Each row's DSO = that row's AROutstanding / that row's NetSales90Day * 90.
     - TOTAL.NetSales90Day (and therefore TOTAL.DSO) is the ADDITIVE ROLLUP of
       every agent+UNASSIGNED row above it — by construction, every column in
       this result set sums correctly from rows to TOTAL, including this one.
     - This means TOTAL.DSO will NOT exactly equal sp_rpt_AR_Aging's own
       company DSO (its result set 3), which computes NetSales90 straight off
       the GL via vw_AccountTree with no bridge/customer join at all. The gap
       between the two DSOs is exactly the bridge gap described above (~₱22
       over the sample window) — immaterial today, but do not chase the two
       into exact agreement; they are deliberately computed two different
       ways for two different reasons. TOTAL.AROutstanding, by contrast, DOES
       tie exactly to sp_rpt_AR_Aging's company AR (see above).

   ACTIVE / DORMANT / NEW ACCOUNTS
   ----------------------------------------------------------------------------
   - Active/Dormant: fixed 30-day window ENDING @DateTo (not today's real
     date, so the proc is usable for past periods), independent of @DateFrom,
     same as sp_rpt_AR_Aging's DSO staying independent of the aging bucket
     parameters. Active = the agent's assigned customer has >= 1
     TransactionChargeSales row with TransactionDate in that window. Dormant
     = assigned but not active. TotalAssignedAccounts is also returned so a
     caller can sanity-check Active + Dormant = TotalAssignedAccounts (a
     future drilldown listing accounts, per sp_rpt_DataHealthCheckDetail's
     pattern, is NOT built here — counts only, v1 scope per the brief).
   - New accounts: customer's MIN(TransactionChargeSales.TransactionDate)
     across ALL of their rows, all-time (not window-limited), falls within
     [@DateFrom, @DateTo]. Grouped by the customer's CURRENT AccountOfficer.

   HARD RULES APPLIED
   ----------------------------------------------------------------------------
   #1  Posted-only wherever the GL is read (tm.Status IN ('POSTED','UPDATED')).
   #2  BranchCode not used anywhere in this proc (see note above); no int
       conversion, no conflation between the two BranchCode axes.
   #3  Revenue classified via vw_AccountTree.AncestorCode + ChartOfAccounts.
       AccountType = 'D' (never LevelNumber, never a hardcoded code list).
   #4  Every date filter is >= @X AND < DATEADD(DAY,1,@Y). Never BETWEEN.
   #5  Signed = Nature 'D' -> Debit-Credit, Nature 'C' -> Credit-Debit.
   #7  RptMnemonicMap.IsInternal excluded from the net-sales bridge.
   #8  Explicit CAST on every output column.
   #9  SELECT-only. No base table is written by this proc.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_Agent_Scorecard', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Agent_Scorecard;
GO

CREATE PROCEDURE dbo.sp_rpt_Agent_Scorecard
    @DateFrom   date,
    @DateTo     date,
    @AgentNames varchar(200) = NULL     -- CSV of Customers.AccountOfficer values; NULL/empty = all agents. See header re: naming.
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));

    /* Prior period = same number of days, immediately before @DateFrom (exact
       pattern from sp_rpt_Exec_Summary, sql/01-exec-overview-data-layer.sql) */
    DECLARE @Days      int      = DATEDIFF(DAY, @DateFrom, @DateTo) + 1;
    DECLARE @PriorFrom datetime = DATEADD(DAY, -@Days, @Start);
    DECLARE @PriorEnd  datetime = @Start;

    /* Trailing 90 days ending @DateTo (DSO net-sales leg) — same window shape
       as sp_rpt_AR_Aging's DSO, sql/05-accounting-aging.sql. Note @Trailing90End
       always equals @End (both are DATEADD(DAY,1,@DateTo)). */
    DECLARE @Trailing90Start datetime = DATEADD(DAY, -89, CAST(@DateTo AS datetime));
    DECLARE @Trailing90End   datetime = @End;

    /* 30-day active/dormant window ending @DateTo, independent of @DateFrom */
    DECLARE @Active30Start datetime = DATEADD(DAY, -29, CAST(@DateTo AS datetime));
    DECLARE @Active30End   datetime = @End;

    /* Load window for the GL revenue pull below: wide enough to cover the
       prior-period comparative AND the trailing-90 DSO window in one pass. */
    DECLARE @LoadStart datetime = CASE WHEN @PriorFrom < @Trailing90Start THEN @PriorFrom ELSE @Trailing90Start END;

    /* ---- Agent name filter, resolved once (empty table = no filter) ------ */
    CREATE TABLE #AgentFilter (AgentName varchar(50) PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(ISNULL(@AgentNames, ''))), '') IS NOT NULL
        INSERT INTO #AgentFilter (AgentName)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@AgentNames, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @FilterAgent bit = CASE WHEN EXISTS (SELECT 1 FROM #AgentFilter) THEN 1 ELSE 0 END;

    /* ---- CustomerKey -> current AgentLabel, the full universe -------------
       Built from Customers first, then topped up with any CustomerKey found
       in TransactionChargeSales that has NO Customers row at all (orphans) —
       both land on 'UNASSIGNED'. This table is the single source of truth
       every metric below joins against, which is what guarantees every
       CustomerKey this proc ever touches is attributed to exactly one row in
       the final result set (an agent, or UNASSIGNED) — never silently
       dropped. ---------------------------------------------------------- */
    CREATE TABLE #CustomerAgent
    (
        CustomerKey char(8)      NOT NULL PRIMARY KEY,
        AgentLabel  varchar(50)  NOT NULL
    );

    INSERT INTO #CustomerAgent (CustomerKey, AgentLabel)
    SELECT
        c.CustomerKey,
        AgentLabel = ISNULL(NULLIF(LTRIM(RTRIM(c.AccountOfficer)), ''), 'UNASSIGNED')
    FROM dbo.Customers AS c;

    INSERT INTO #CustomerAgent (CustomerKey, AgentLabel)
    SELECT DISTINCT t.CustomerKey, 'UNASSIGNED'
    FROM dbo.TransactionChargeSales AS t
    WHERE NOT EXISTS (SELECT 1 FROM #CustomerAgent AS ca WHERE ca.CustomerKey = t.CustomerKey);

    /* ---- Revenue GL lines, bridged to a customer -------------------------
       INNER JOIN to TransactionChargeSales is the bridge itself — rows that
       fail to bridge (see header caveat: OR-DISC/OR-EWT-DISC today) are
       excluded here by construction, which is exactly the disclosed
       limitation, not a bug to fix in this pass. */
    CREATE TABLE #RevenueLine
    (
        TicketDate  datetime NOT NULL,
        Signed      money    NOT NULL,
        CustomerKey char(8)  NOT NULL
    );

    INSERT INTO #RevenueLine (TicketDate, Signed, CustomerKey)
    SELECT
        td.TicketDate,
        Signed = CASE coa.Nature WHEN 'D' THEN td.Debit - td.Credit ELSE td.Credit - td.Debit END,
        tcs.CustomerKey
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
    INNER JOIN dbo.TransactionChargeSales AS tcs
        ON tcs.ReferenceNo = tm.ReferenceNumber      -- THE BRIDGE (see header)
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND coa.AccountType = 'D'
      AND t.AncestorCode IN ('401', '402', '40103')
      AND ISNULL(mm.IsInternal, 0) = 0
      AND td.TicketDate >= @LoadStart
      AND td.TicketDate <  @End;

    /* ---- Per-customer sales rollup, then per-agent ----------------------- */
    CREATE TABLE #CustSales
    (
        CustomerKey   char(8) NOT NULL PRIMARY KEY,
        NetSales      money   NOT NULL,
        NetSalesPrior money   NOT NULL,
        NetSales90    money   NOT NULL
    );

    INSERT INTO #CustSales (CustomerKey, NetSales, NetSalesPrior, NetSales90)
    SELECT
        CustomerKey,
        NetSales      = SUM(CASE WHEN TicketDate >= @Start          AND TicketDate < @End            THEN Signed ELSE 0 END),
        NetSalesPrior = SUM(CASE WHEN TicketDate >= @PriorFrom       AND TicketDate < @PriorEnd        THEN Signed ELSE 0 END),
        NetSales90    = SUM(CASE WHEN TicketDate >= @Trailing90Start AND TicketDate < @Trailing90End   THEN Signed ELSE 0 END)
    FROM #RevenueLine
    GROUP BY CustomerKey;

    CREATE TABLE #AgentSales
    (
        AgentLabel    varchar(50) NOT NULL PRIMARY KEY,
        NetSales      money       NOT NULL,
        NetSalesPrior money       NOT NULL,
        NetSales90    money       NOT NULL
    );

    INSERT INTO #AgentSales (AgentLabel, NetSales, NetSalesPrior, NetSales90)
    SELECT
        ca.AgentLabel,
        ISNULL(SUM(cs.NetSales), 0),
        ISNULL(SUM(cs.NetSalesPrior), 0),
        ISNULL(SUM(cs.NetSales90), 0)
    FROM #CustomerAgent AS ca
    LEFT JOIN #CustSales AS cs
        ON cs.CustomerKey = ca.CustomerKey
    GROUP BY ca.AgentLabel;

    /* ---- AR open items, bucketed exactly like sp_rpt_AR_Aging ------------- */
    CREATE TABLE #AROpen
    (
        CustomerKey char(8)        NOT NULL,
        Balance     decimal(18,2)  NOT NULL,
        AgeDays     int            NOT NULL
    );

    INSERT INTO #AROpen (CustomerKey, Balance, AgeDays)
    SELECT
        t.CustomerKey,
        t.Balance,
        AgeDays = DATEDIFF(DAY, t.TransactionDate, @DateTo)
    FROM dbo.TransactionChargeSales AS t
    WHERE t.Balance > 0;

    CREATE TABLE #AgentAR
    (
        AgentLabel      varchar(50)   NOT NULL PRIMARY KEY,
        AROutstanding   decimal(18,2) NOT NULL,
        ARPastDue31Plus decimal(18,2) NOT NULL,
        OldestAgeDays   int           NULL
    );

    INSERT INTO #AgentAR (AgentLabel, AROutstanding, ARPastDue31Plus, OldestAgeDays)
    SELECT
        ca.AgentLabel,
        ISNULL(SUM(o.Balance), 0),
        ISNULL(SUM(CASE WHEN o.AgeDays > 30 THEN o.Balance ELSE 0 END), 0),
        MAX(o.AgeDays)
    FROM #CustomerAgent AS ca
    LEFT JOIN #AROpen AS o
        ON o.CustomerKey = ca.CustomerKey
    GROUP BY ca.AgentLabel;

    /* ---- Active (30 days ending @DateTo) vs dormant ----------------------- */
    CREATE TABLE #Activity
    (
        CustomerKey char(8) NOT NULL PRIMARY KEY,
        IsActive    bit     NOT NULL
    );

    INSERT INTO #Activity (CustomerKey, IsActive)
    SELECT
        ca.CustomerKey,
        IsActive = CASE WHEN EXISTS (
                        SELECT 1 FROM dbo.TransactionChargeSales AS t
                        WHERE t.CustomerKey = ca.CustomerKey
                          AND t.TransactionDate >= @Active30Start
                          AND t.TransactionDate <  @Active30End
                   ) THEN 1 ELSE 0 END
    FROM #CustomerAgent AS ca;

    CREATE TABLE #AgentActivity
    (
        AgentLabel            varchar(50) NOT NULL PRIMARY KEY,
        TotalAssignedAccounts int         NOT NULL,
        ActiveAccounts        int         NOT NULL,
        DormantAccounts       int         NOT NULL
    );

    INSERT INTO #AgentActivity (AgentLabel, TotalAssignedAccounts, ActiveAccounts, DormantAccounts)
    SELECT
        ca.AgentLabel,
        COUNT(*),
        SUM(CASE WHEN a.IsActive = 1 THEN 1 ELSE 0 END),
        SUM(CASE WHEN a.IsActive = 0 THEN 1 ELSE 0 END)
    FROM #CustomerAgent AS ca
    INNER JOIN #Activity AS a
        ON a.CustomerKey = ca.CustomerKey
    GROUP BY ca.AgentLabel;

    /* ---- New accounts: first-ever order date falls in [@DateFrom,@DateTo] */
    CREATE TABLE #FirstOrder
    (
        CustomerKey    char(8) NOT NULL PRIMARY KEY,
        FirstOrderDate date    NOT NULL
    );

    INSERT INTO #FirstOrder (CustomerKey, FirstOrderDate)
    SELECT CustomerKey, MIN(TransactionDate)
    FROM dbo.TransactionChargeSales
    GROUP BY CustomerKey;

    CREATE TABLE #AgentNew
    (
        AgentLabel  varchar(50) NOT NULL PRIMARY KEY,
        NewAccounts int         NOT NULL
    );

    INSERT INTO #AgentNew (AgentLabel, NewAccounts)
    SELECT ca.AgentLabel, COUNT(*)
    FROM #CustomerAgent AS ca
    INNER JOIN #FirstOrder AS f
        ON f.CustomerKey = ca.CustomerKey
    WHERE f.FirstOrderDate >= @DateFrom
      AND f.FirstOrderDate <  DATEADD(DAY, 1, @DateTo)
    GROUP BY ca.AgentLabel;

    /* ---- Final result set: AGENT rows (optionally filtered) + always-on
       UNASSIGNED row + always-on company-wide TOTAL row -------------------- */
    ;WITH AgentList AS (
        SELECT DISTINCT AgentLabel FROM #CustomerAgent
    )
    SELECT
        AgentLabel            = CAST(al.AgentLabel AS varchar(50)),
        RowType               = CAST(CASE WHEN al.AgentLabel = 'UNASSIGNED' THEN 'UNASSIGNED' ELSE 'AGENT' END AS varchar(10)),
        NetSales              = CAST(ISNULL(s.NetSales, 0) AS decimal(18,2)),
        NetSalesPrior         = CAST(ISNULL(s.NetSalesPrior, 0) AS decimal(18,2)),
        TotalAssignedAccounts = CAST(ISNULL(act.TotalAssignedAccounts, 0) AS int),
        ActiveAccounts        = CAST(ISNULL(act.ActiveAccounts, 0) AS int),
        DormantAccounts       = CAST(ISNULL(act.DormantAccounts, 0) AS int),
        NewAccounts           = CAST(ISNULL(nw.NewAccounts, 0) AS int),
        AROutstanding         = CAST(ISNULL(ar.AROutstanding, 0) AS decimal(18,2)),
        ARPastDue31Plus       = CAST(ISNULL(ar.ARPastDue31Plus, 0) AS decimal(18,2)),
        ARPastDuePct          = CAST(CASE WHEN ISNULL(ar.AROutstanding, 0) = 0 THEN NULL
                                           ELSE ar.ARPastDue31Plus / ar.AROutstanding * 100 END AS decimal(9,2)),
        OldestOpenItemAgeDays = CAST(ar.OldestAgeDays AS int),
        NetSales90Day         = CAST(ISNULL(s.NetSales90, 0) AS decimal(18,2)),
        DSO                   = CAST(CASE WHEN ISNULL(s.NetSales90, 0) <= 0 THEN NULL
                                           ELSE ISNULL(ar.AROutstanding, 0) / s.NetSales90 * 90 END AS decimal(9,1))
    FROM AgentList AS al
    LEFT JOIN #AgentSales    AS s   ON s.AgentLabel   = al.AgentLabel
    LEFT JOIN #AgentAR       AS ar  ON ar.AgentLabel  = al.AgentLabel
    LEFT JOIN #AgentActivity AS act ON act.AgentLabel = al.AgentLabel
    LEFT JOIN #AgentNew      AS nw  ON nw.AgentLabel  = al.AgentLabel
    WHERE al.AgentLabel = 'UNASSIGNED'                 -- always included, never filtered
       OR @FilterAgent = 0                              -- no filter supplied = all agents
       OR al.AgentLabel IN (SELECT AgentName FROM #AgentFilter)

    UNION ALL

    SELECT
        AgentLabel            = CAST('TOTAL' AS varchar(50)),
        RowType               = CAST('TOTAL' AS varchar(10)),
        NetSales              = CAST(ISNULL((SELECT SUM(NetSales)      FROM #AgentSales), 0) AS decimal(18,2)),
        NetSalesPrior         = CAST(ISNULL((SELECT SUM(NetSalesPrior) FROM #AgentSales), 0) AS decimal(18,2)),
        TotalAssignedAccounts = CAST(ISNULL((SELECT SUM(TotalAssignedAccounts) FROM #AgentActivity), 0) AS int),
        ActiveAccounts        = CAST(ISNULL((SELECT SUM(ActiveAccounts)        FROM #AgentActivity), 0) AS int),
        DormantAccounts       = CAST(ISNULL((SELECT SUM(DormantAccounts)       FROM #AgentActivity), 0) AS int),
        NewAccounts           = CAST(ISNULL((SELECT SUM(NewAccounts) FROM #AgentNew), 0) AS int),
        AROutstanding         = CAST(ISNULL((SELECT SUM(AROutstanding)   FROM #AgentAR), 0) AS decimal(18,2)),
        ARPastDue31Plus       = CAST(ISNULL((SELECT SUM(ARPastDue31Plus) FROM #AgentAR), 0) AS decimal(18,2)),
        ARPastDuePct          = CAST(CASE WHEN ISNULL((SELECT SUM(AROutstanding) FROM #AgentAR), 0) = 0 THEN NULL
                                           ELSE (SELECT SUM(ARPastDue31Plus) FROM #AgentAR)
                                                / (SELECT SUM(AROutstanding) FROM #AgentAR) * 100 END AS decimal(9,2)),
        OldestOpenItemAgeDays = CAST((SELECT MAX(OldestAgeDays) FROM #AgentAR) AS int),
        NetSales90Day         = CAST(ISNULL((SELECT SUM(NetSales90) FROM #AgentSales), 0) AS decimal(18,2)),
        DSO                   = CAST(CASE WHEN ISNULL((SELECT SUM(NetSales90) FROM #AgentSales), 0) <= 0 THEN NULL
                                           ELSE (SELECT SUM(AROutstanding) FROM #AgentAR)
                                                / (SELECT SUM(NetSales90) FROM #AgentSales) * 90 END AS decimal(9,1))
    ORDER BY RowType, NetSales DESC;

    DROP TABLE #FirstOrder;
    DROP TABLE #AgentNew;
    DROP TABLE #Activity;
    DROP TABLE #AgentActivity;
    DROP TABLE #AROpen;
    DROP TABLE #AgentAR;
    DROP TABLE #CustSales;
    DROP TABLE #AgentSales;
    DROP TABLE #RevenueLine;
    DROP TABLE #CustomerAgent;
    DROP TABLE #AgentFilter;
END
GO


/* ============================================================================
   SMOKE TEST
   Run against CORECSERP_002_DEV. Live data today (2026-09-23): posted tickets
   span 2026-07-31 .. 2026-09-23.
============================================================================ */
/*
-- 1. Basic run, all agents, a representative window
EXEC dbo.sp_rpt_Agent_Scorecard @DateFrom = '2026-08-01', @DateTo = '2026-09-22';

-- 2. Filtered to a couple of named agents — UNASSIGNED and TOTAL must still appear
EXEC dbo.sp_rpt_Agent_Scorecard @DateFrom = '2026-08-01', @DateTo = '2026-09-22',
                                 @AgentNames = 'Rose Belle Acoyong,Larry C. Libradilla';

-- 3. Zero-match filter — TOTAL/UNASSIGNED must still return real numbers, no NULLs
EXEC dbo.sp_rpt_Agent_Scorecard @DateFrom = '2026-08-01', @DateTo = '2026-09-22',
                                 @AgentNames = 'ZZZ-NOMATCH';

-- 4. TIE-OUT (the one accounting-reviewer will re-check first): sum of every
--    row's AROutstanding here (agents + UNASSIGNED + the TOTAL row itself,
--    hence dividing by 2) must equal sp_rpt_AR_Aging's company TotalOutstanding
--    for the same @DateTo.
EXEC dbo.sp_rpt_Agent_Scorecard @DateFrom = '2026-08-01', @DateTo = '2026-09-22';
EXEC dbo.sp_rpt_AR_Aging        @AsOfDate = '2026-09-22';
*/
