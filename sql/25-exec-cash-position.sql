/* ============================================================================
   CORE REPORTING PORTAL — EXECUTIVE OVERVIEW: CASH POSITION DETAIL
   Brand-new object, first creation — no prior version anywhere, so nothing
   to preserve under an _OLD suffix (that rule applies to ALTERs).

   Target DB: COREX001 — the sole default dev tier per CLAUDE.md as of
   2026-09-27 (CORECSERP_002_DEV retired same day). Applied directly, no
   confirmation needed, per the current DB change protocol. NOT applied to
   CORECSJFC2026_STAGING.

   Ask answered: sp_rpt_Exec_Summary (sql/01-exec-overview-data-layer.sql,
   ~line 396) already surfaces a single lump CashPosition figure. Executives
   and the controller asked for the underlying detail — which bank accounts,
   which branches, how much in each — not just the lump total. This proc is
   that detail, built to tie out exactly to the existing lump figure.

   ----------------------------------------------------------------------------
   SCHEMA — CONFIRMED LIVE ON COREX001 THIS PASS (2026-09-27), NOT ASSUMED
   ----------------------------------------------------------------------------
   dbo.ChartOfAccounts: AccountCode varchar(50), Description varchar(256)
     (there is NO "AccountName" column — "AccountName" in this proc's output
     is an alias over Description), AccountType varchar(1), LevelNumber
     smallint, SummaryAccount varchar(20), GLSL char(1), BranchCode char(5),
     YearEndIndicator char(2) (despite the name, this column actually holds
     'BS'/'IS' book-section codes, not a year-end flag — confirmed by value
     inspection; sp_rpt_Exec_Summary's #Line already relies on this same
     quirk, aliasing it straight into a column literally named Book), Nature
     char(1), DueToFromIndicator varchar(50).

   10101 / 10102 CONFIRMED:
     10101 = 'CASH ON HAND' (AccountType 'S', summary node). Its ONLY detail
       (AccountType='D') child: 1010101 'PETTY CASH FUND'.
     10102 = 'CASH IN BANK' (AccountType 'S', summary node), with two
       intermediate summary children — 1010201 'CASH IN BANK - LOCAL
       CURRENCY' (12 detail accounts, one per named bank/currency instance,
       e.g. BDO PESO1/PESO2, EASTWEST, WEALTHBANK, UNION PESO1/2, MBTC
       PESO1/2, BPI PESO1/2, PNB PESO/PESO2) and 1010202 'CASH IN BANK -
       FOREIGN CURRENCY' (14 detail accounts, USD/EUR instances of BDO/MBTC/
       BPI/PNB). 27 detail accounts total under the two ancestors combined.
       Both labels are exactly what the brief guessed — confirmed, not
       assumed.

   dbo.RptMnemonicMap CHECKED, NOT USED — reasoning below (see "CLASSIFICATION
   SOURCE" section). Columns: Mnemonic, Family, Description, IsInternal,
   IsCrossBranch. No AccountCode/account-tree column exists on this table at
   all — it classifies TRANSACTION mnemonics (journal-entry types like
   'CR-CASH', 'EXP-AP-EWT'), not chart-of-accounts nodes. There is no
   existing 'IsCash' flag or equivalent to reuse.

   dbo.ChartOfAccounts.BranchCode is '888' on EVERY row, no exceptions
   (CONFIRMED: SELECT DISTINCT BranchCode FROM ChartOfAccounts returns a
   single value, '888'). The chart itself is not branch-specific — it is
   one master chart shared by all branches. This means the account's "home"
   branch is meaningless for a branch breakdown; the branch dimension for
   this report has to come from the LEDGER (TicketDetails.BranchCode), not
   the chart.

   dbo.TicketDetails (NOTE: plural — "TicketDetail" singular does not exist
   as an object; confirmed via sys.objects before trusting the brief's
   working name) columns: TicketDate datetime, SupplementaryNumber tinyint,
   BranchCode varchar(5), ReferenceKey varchar(50), TicketNumber varchar(50),
   ReferenceNumber varchar(50), AccountCode varchar(20), Debit money, Credit
   money, CostCenter varchar(10), Particulars varchar(400). Joined to
   TicketMaster on (TicketDate, SupplementaryNumber, BranchCode,
   TicketNumber) — same composite key sp_rpt_Exec_Summary's #Line already
   uses.

   ----------------------------------------------------------------------------
   BRANCH BREAKDOWN — CONFIRMED MEANINGFUL, BUT NOT "WHICH BRANCH OWNS THIS
   BANK ACCOUNT" — IT IS "WHICH BRANCH'S POSTINGS TOUCHED THIS GL ACCOUNT"
   ----------------------------------------------------------------------------
   Live posting data (CONFIRMED, not assumed): the SAME bank GL account code
   is posted to by MULTIPLE branches. E.g. 101020101 (BDO PESO1) has posted
   lines from branches 001, 002, 003, 004, 005, 007, 009, 010, 011, 013, AND
   888 — ten satellite branches plus Head Office all post against one
   physical HO bank account. This is the expected pattern for this business:
   satellite branches remit cash collections into HO-held bank accounts, and
   the branch tag on the ledger line records WHOSE remittance activity that
   was, not a separate branch-owned bank account. So a branch breakdown here
   answers "how much of this account's balance is attributable to each
   branch's posting activity" (useful for remittance reconciliation), NOT
   "which branch physically holds this account" (there is exactly one
   physical account per AccountCode; ChartOfAccounts confirms this — the
   chart has no per-branch duplicate account codes for cash).
   By contrast, 1010101 PETTY CASH FUND has posted activity from branch 888
   ONLY (2 lines) in the live data — no branch currently carries its own
   distinct petty-cash GL account per this data set. Branch breakdown is
   therefore genuinely informative for Cash in Bank (multi-branch activity
   exists) and currently a single row for Cash on Hand (not noise — it is
   the honest answer that only HO has posted against petty cash so far).

   ----------------------------------------------------------------------------
   CLASSIFICATION SOURCE — KEPT sp_rpt_Exec_Summary'S EXISTING CONVENTION
   (hardcoded ancestor literals via vw_AccountTree), NOT SWITCHED TO
   RptMnemonicMap
   ----------------------------------------------------------------------------
   Hard Rule #3 says classification comes from vw_AccountTree + RptMnemonicMap,
   never hardcoded account-code lists. RptMnemonicMap, confirmed above, has
   no column that classifies balance-sheet/chart-of-accounts NODES (like
   "is this a cash account") — every row it holds classifies a transaction
   MNEMONIC (a journal-entry recipe), which is an orthogonal concept used for
   IsInternal/IsCrossBranch (P&L-side exclusions), not for BS account
   groupings. sp_rpt_Exec_Summary's own BS section (NetSales/COGS/OpEx use
   RptMnemonicMap-adjacent hardcoded ancestor groups too, e.g. '401','402',
   '40103','5','6', and the BS tiles use '101030101' for AR, '20101'/'20102'/
   '20103' for AP, '1010401'/'1010402' for inventory) hardcodes EVERY
   balance-sheet grouping the same way — via vw_AccountTree.AncestorCode
   literals, not RptMnemonicMap. There is no cleaner RptMnemonicMap-driven
   join available for cash specifically; building one would mean inventing a
   new mapping table/column that doesn't exist today, which is out of scope
   for a single report. DECISION: follow the existing, already-consistent
   precedent — AncestorCode IN ('10101','10102') via vw_AccountTree, with
   Postability (which detail rows are real, postable accounts) decided by
   ChartOfAccounts.AccountType = 'D', never LevelNumber (LevelNumber varies:
   1010101 sits at level 3, the 26 bank accounts sit at level 4 — both are
   detail, both belong in this report, which is exactly why AccountType, not
   LevelNumber, gates inclusion here).

   ----------------------------------------------------------------------------
   ZERO-BALANCE vs NEVER-POSTED — INCLUDE THE FORMER, EXCLUDE THE LATTER
   ----------------------------------------------------------------------------
   CONFIRMED LIVE: of the 27 detail accounts under 10101/10102, 14 have ZERO
   TicketDetails rows ever posted against them (EASTWEST, WEALTHBANK, BDO
   USD2, BDO EURO1/2, MBTC USD2, MBTC EURO1/2, BPI EURO1/2, PNB EURO1/2 —
   entirely unused foreign-currency/backup accounts in this data set) vs 13
   with real posting history. This proc's Lines CTE is built from an INNER
   JOIN against TicketDetails/TicketMaster, so an (AccountCode, BranchCode)
   combination only appears as a row if at least one posted line exists for
   it — never-posted accounts are correctly absent. A combination that HAS
   posted activity netting to exactly zero as of @AsOfDate WILL still appear
   with Balance = 0.00 (the INNER JOIN only requires >=1 row to exist in the
   GROUP BY, not a non-zero SUM) — a controller seeing a $0 balance on an
   account/branch pair that has genuine history is meaningfully different
   from that pair never having existed at all, and this design preserves
   that distinction rather than collapsing both into "absent".

   ----------------------------------------------------------------------------
   TIE-OUT — CONFIRMED EXACT MATCH AGAINST sp_rpt_Exec_Summary.CashPosition
   ----------------------------------------------------------------------------
   Ran both procs for the same as-of date (2026-09-26, the live MAX posted
   TicketDate in this data set at investigation time):
     EXEC dbo.sp_rpt_Exec_Summary @DateFrom='2026-09-01', @DateTo='2026-09-26'
       -> CashPosition = 20427301.3100
     SUM(Balance) FROM dbo.sp_rpt_Exec_CashPosition @AsOfDate='2026-09-26'
       -> 20427301.3100, across 27 (AccountCode, BranchCode) rows.
   Exact match, to the penny, no discrepancy to chase. Both procs replicate
   the identical filter set (Status IN ('POSTED','UPDATED'), AccountType='D'
   via vw_AccountTree, TicketDate < DATEADD(DAY,1,@AsOfDate), same Nature-
   based signed formula) against the same underlying rows, so this is the
   expected result rather than a coincidence — documented per CLAUDE.md's
   subledger-vs-GL-control discipline (same spirit as the AR/AP aging
   tie-out), not skipped just because it happened to match on the first try.

   ----------------------------------------------------------------------------
   DATA-QUALITY / SURPRISE NOTES TO FLAG (not fixed here — out of scope for a
   read-only reporting proc; flagging per house discipline)
   ----------------------------------------------------------------------------
   1. Several bank accounts carry NEGATIVE cumulative balances as of
      2026-09-26 (e.g. 101020101 BDO PESO1 at HO: -11,585,791.16;
      101020111 PNB PESO: -10,290,068.52; 101020112 PNB PESO2: -11,421,805.26;
      101020201 BDO USD1: -6,533,699.77). A real bank account cannot have a
      negative ledger balance in the way an AP account can — this almost
      certainly reflects an incomplete/missing opening-balance journal entry
      in this data set (MIN posted TicketDate is 2026-07-24, suggesting the
      GL history visible here starts mid-stream without a balancing beginning
      balance), not an actual overdraft. Flagged for the developer/controller
      to confirm against the real bank statements before trusting any single
      account's absolute balance — the AGGREGATE CashPosition figure this
      proc ties out to is presumably still right (it already existed and is
      presumably reconciled elsewhere), but per-account distribution should
      be treated with caution until opening balances are confirmed loaded.
   2. Branch roster now includes '013' (OZAMIZ BRANCH) and '014' (DAVAO
      HORECA) — beyond the '001'-'012' range CLAUDE.md's Hard Rule #2 uses as
      an illustrative example. Not a bug (BranchCode is still always varchar,
      per the rule's actual requirement), just noting the rule's example
      range is stale versus the live 15-row dbo.Branches roster.

   ----------------------------------------------------------------------------
   PARAMETERS
   ----------------------------------------------------------------------------
   @AsOfDate    date = NULL, defaults to today (CAST(SYSDATETIME() AS date)).
     Point-in-time balance-sheet figure, cumulative to-date — NOT a date-range
     flow. Same convention as sp_rpt_Exec_Summary's BS section:
     TicketDate < DATEADD(DAY,1,@AsOfDate), posted-only.
   @BranchCodes varchar(200) = NULL, optional CSV filter, same STRING_SPLIT/
     #Branch temp-table convention as every sibling sp_rpt_Exec_* proc
     (requires DB compat level >= 130; COREX001 confirmed at 160). Filtering
     by branch only restricts WHICH branches' postings are included per
     account — it does not change which accounts qualify as "cash", and the
     tie-out above only holds with no branch filter applied (matching
     sp_rpt_Exec_Summary's own branch-filtered behavior, which likewise only
     ties to an unfiltered total when unfiltered itself).
============================================================================ */


IF OBJECT_ID('dbo.sp_rpt_Exec_CashPosition', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Exec_CashPosition;
GO

CREATE PROCEDURE dbo.sp_rpt_Exec_CashPosition
    @AsOfDate    date = NULL,
    @BranchCodes varchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @AsOfDate = ISNULL(@AsOfDate, CAST(SYSDATETIME() AS date));
    DECLARE @End datetime = DATEADD(DAY, 1, CAST(@AsOfDate AS datetime));

    /* Branch filter resolved once into a temp table, same convention as
       sp_rpt_Exec_Summary. Empty table = no filter. */
    CREATE TABLE #Branch (BranchCode varchar(5) PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(ISNULL(@BranchCodes, ''))), '') IS NOT NULL
        INSERT INTO #Branch (BranchCode)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@BranchCodes, ',')
        WHERE LTRIM(RTRIM(value)) <> '';

    DECLARE @FilterBranch bit = CASE WHEN EXISTS (SELECT 1 FROM #Branch) THEN 1 ELSE 0 END;

    ;WITH CashAccounts AS
    (
        /* Detail (postable) accounts only, per Hard Rule #3 — AccountType,
           never LevelNumber. Ancestor literals kept consistent with
           sp_rpt_Exec_Summary's own BS section; see header for why
           RptMnemonicMap does not offer a cleaner join for this grouping. */
        SELECT DISTINCT
            t.AccountCode,
            t.Description AS AccountName,
            Classification = CASE WHEN t.AncestorCode = '10101' THEN 'Cash on Hand'
                                   ELSE 'Cash in Bank' END
        FROM dbo.vw_AccountTree AS t
        WHERE t.AncestorCode IN ('10101', '10102')
          AND t.AccountType = 'D'
    ),
    Lines AS
    (
        /* Posted-only, signed per Nature, cumulative to @AsOfDate. Only
           (AccountCode, BranchCode) pairs with real posting history reach
           this CTE — never-posted accounts are correctly absent (see
           header). */
        SELECT
            td.AccountCode,
            td.BranchCode,
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
        WHERE tm.Status IN ('POSTED', 'UPDATED')
          AND td.TicketDate < @End
          AND td.AccountCode IN (SELECT AccountCode FROM CashAccounts)
          AND (@FilterBranch = 0
               OR td.BranchCode IN (SELECT BranchCode FROM #Branch))
    )
    SELECT
        AccountCode    = CAST(ca.AccountCode AS varchar(20)),
        AccountName    = CAST(ca.AccountName AS varchar(256)),
        Classification = CAST(ca.Classification AS varchar(20)),
        BranchCode     = CAST(l.BranchCode AS varchar(5)),
        BranchName     = CAST(ISNULL(b.BranchName, '') AS varchar(128)),
        DisplayText    = CAST(l.BranchCode + '-' + ISNULL(b.BranchName, '') AS varchar(150)),
        Balance        = CAST(SUM(l.Signed) AS decimal(18,2)),
        AsOf           = CAST(@AsOfDate AS date)
    FROM Lines AS l
    INNER JOIN CashAccounts AS ca
        ON ca.AccountCode = l.AccountCode
    LEFT JOIN dbo.Branches AS b
        ON b.BranchCode = l.BranchCode
    GROUP BY ca.AccountCode, ca.AccountName, ca.Classification, l.BranchCode, b.BranchName
    ORDER BY ca.Classification, ca.AccountCode, l.BranchCode;

    DROP TABLE #Branch;
END
GO


/* ============================================================================
   SMOKE TEST + TIE-OUT CHECK
============================================================================ */
/*
-- Detail report, explicit as-of date matching the tie-out below:
EXEC dbo.sp_rpt_Exec_CashPosition @AsOfDate = '2026-09-26';

-- Same, with a branch filter (subset of the unfiltered result, HO only):
EXEC dbo.sp_rpt_Exec_CashPosition @AsOfDate = '2026-09-26', @BranchCodes = '888';

-- Default @AsOfDate (today):
EXEC dbo.sp_rpt_Exec_CashPosition;

-- Tie-out: SUM(Balance) from the detail proc must equal CashPosition from
-- the existing summary proc for the same as-of date. CONFIRMED MATCH at
-- investigation time: both returned 20427301.3100 for @AsOfDate/@DateTo =
-- 2026-09-26 (@DateFrom is irrelevant to the BS figure, see sp_rpt_Exec_
-- Summary's own logic — only @DateTo bounds the cumulative BS window).
DECLARE @Tie TABLE
(
    AccountCode    varchar(20),
    AccountName    varchar(256),
    Classification varchar(20),
    BranchCode     varchar(5),
    BranchName     varchar(128),
    DisplayText    varchar(150),
    Balance        decimal(18,2),
    AsOf           date
);
INSERT INTO @Tie EXEC dbo.sp_rpt_Exec_CashPosition @AsOfDate = '2026-09-26';
SELECT DetailTotal = SUM(Balance) FROM @Tie;
EXEC dbo.sp_rpt_Exec_Summary @DateFrom = '2026-09-01', @DateTo = '2026-09-26';
-- Compare DetailTotal above against the CashPosition column in this result.
*/
