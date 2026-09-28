/* ============================================================================
   CORE REPORTING PORTAL — EXECUTIVE OVERVIEW: INVENTORY BY BRANCH
   Originally targeted CORECSERP_002_DEV only (per the protocol in force at
   the time). This is a brand-new object (no prior version existed anywhere),
   so there was nothing to preserve under an _OLD suffix; the rename-old-
   object rule applies to ALTERS, not first creation.

   APPLIED TO COREX001 on 2026-09-27, with the developer's explicit
   authorization ("yes sync to COREX001"). Verified byte-identical
   (normalized) against the CORECSERP_002_DEV definition, then smoke-tested
   live: 15 rows (all branches, including 014-DAVAO HORECA at 0/0/0 per the
   LEFT JOIN design below), production-value figures as expected (e.g.
   003-BACOLOD BRANCH ~114.6K qty / ~PHP 6.0B on-hand value). ZeroCostQuantityPct
   came back 0.0000 for every branch on COREX001 (unlike DEV, where Head
   Office showed a real ~3.76% cost gap) — COREX001's copied cost data simply
   doesn't reproduce that same gap; not a bug in this proc.

   As of 2026-09-27, CORECSERP_002_DEV is RETIRED and COREX001 is the sole
   default dev DB (see CLAUDE.md) — this note is kept as history, not as an
   indication that CORECSERP_002_DEV still needs separate tracking.

   New proc: dbo.sp_rpt_Exec_InventoryByBranch — one row per branch, current
   on-hand quantity + peso value + lot/line count, for the Executive Overview
   dashboard (Views/Dashboard/Executive.cshtml). Feeds a "which branch is
   carrying the most/least stock" view.

   ----------------------------------------------------------------------------
   SCHEMA — CONFIRMED LIVE ON CORECSERP_002_DEV THIS PASS (2026-09-26), NOT
   RE-DERIVED FROM SCRATCH — sql/23-exception-center-inventory.sql's header
   already documented dbo.Inventory in detail; re-verified live via
   INFORMATION_SCHEMA.COLUMNS before writing this script, per house
   discipline ("re-verify anything you rely on live before trusting it"):
     dbo.Inventory: Branch varchar(5) NULL — CONFIRMED, matches sql/23
       exactly (NOT BranchCode). Quantity decimal(18,3) NULL, Cost
       decimal(18,2) NULL, Available decimal(18,3) NULL, IsStock bit NULL.
       7,835 live rows, 7,813 with IsStock = 1. Same lot/batch-level ledger
       sql/23 described (multiple rows per Product+Branch, one per receiving
       batch), not a one-row-per-product snapshot.
     dbo.Branches: BranchCode varchar(128) NOT NULL, BranchName varchar(128)
       NULL. 15 rows: 001-013, 014 (DAVAO HORECA), 888 (HEAD OFFICE CEBU).
       CONFIRMED LIVE: dbo.Inventory has rows for 14 of these 15 branch codes
       (001-013 and 888) — branch 014 (DAVAO HORECA) currently has ZERO
       Inventory rows of any kind. This is exactly the case the brief's
       LEFT JOIN requirement exists for: 014 must still appear on this
       report, honestly at 0/0/0, not silently dropped.
     MIN(Quantity) = 0.000, MAX(Quantity) = 28016.790, CONFIRMED 0 rows with
       Quantity < 0 anywhere in the table today (matches sql/23's own
       INV-NEGATIVE-QTY finding of 0 live rows) — see "NEGATIVE QUANTITY"
       section below for what happens if that ever changes.

   ----------------------------------------------------------------------------
   QUANTITY vs AVAILABLE — DELIBERATE CHOICE, DOCUMENTED PER THE BRIEF'S ASK
   ----------------------------------------------------------------------------
   This proc uses Quantity (raw physical on-hand), NOT Available (Quantity net
   of active sales-order reservations — confirmed distinct in sql/23, and
   re-confirmed here: SUM(Available) is 2%-24% lower than SUM(Quantity) on
   every branch sampled, e.g. branch 008: Quantity 28,191.65 vs Available
   12,851.34 — reservations are material, not a rounding difference).
   Judgment call, reasoning below:
     - The brief this proc answers is "how much stock is physically sitting
       in each branch" — a warehousing/carrying-cost/loss-exposure question
       an executive asks about physical footprint, not a "can I still sell
       this" question. Quantity is the correct literal answer to that
       question; Available answers a DIFFERENT question (sellable capacity
       net of commitments) that belongs to a Sales/fulfillment view, not this
       one.
     - Counter-argument acknowledged: if the intent were instead "how much
       could each branch still sell right now", Available would be the right
       column and this proc's numbers would systematically overstate that.
       Flagging this explicitly so the developer can redirect if the actual
       business question was the sellable-capacity one, not the physical-
       footprint one — this is a genuine either-way call, not a settled fact.
     - A secondary reason to prefer Quantity here: dbo.Inventory is a
       lot-level ledger orthogonal to the general ledger's own inventory
       balance (accounts 1010401/1010402, already surfaced ERP-wide by
       sp_rpt_Exec_Summary's InventoryOnHand/InventoryInTransit tiles). A
       future subledger-vs-GL tie-out check (same spirit as the AR/AP
       aging tie-out CLAUDE.md calls for) would need to reconcile THIS
       proc's OnHandValue against the GL's inventory account balance, and a
       physical Quantity-based figure is the correct side of that
       reconciliation — Available is a sales-side concept the GL doesn't
       track a mirror balance for. Not built here (out of scope), but noted
       as a natural next check.

   ----------------------------------------------------------------------------
   NEGATIVE / ZERO QUANTITY — EXCLUDED, NOT NETTED, REASONING BELOW
   ----------------------------------------------------------------------------
   Filter is Quantity > 0. Zero-quantity rows are inert (a depleted lot still
   on file) and correctly contribute nothing either way. Negative-quantity
   rows are the substantive decision the brief asks to make explicit:
   CONFIRMED LIVE, there are 0 such rows today, so this decision has zero
   effect on the current numbers — but the correct behaviour if one ever
   appears is to EXCLUDE it from this SUM, not net it in as an offset.
   Reasoning: sql/23's own INV-NEGATIVE-QTY check treats a negative on-hand
   quantity as a "standing data-integrity red flag" — a FIFO-depletion bug,
   an unvalidated over-issuance, or a reconciliation failure, never a
   legitimate reconciling entry (a real return or write-off is booked as its
   own transaction/adjustment, not as a negative Quantity sitting on a lot
   row). Silently netting such a row into a branch's total would let a data
   quality bug quietly shrink a headline number with no visible trace —
   exactly the "present but wrong" failure CLAUDE.md warns about. The
   right place for a negative-quantity lot to surface is INV-NEGATIVE-QTY's
   own drill-down (already built, sql/23), not folded into this tile.

   ----------------------------------------------------------------------------
   IsStock = 1 — FOLLOWED, SAME PRECEDENT AS sql/23, MATERIALITY CHECKED
   ----------------------------------------------------------------------------
   sql/23 confirmed IsStock = 0 marks a small (22-row) set the ERP itself has
   already flagged as not genuine trackable stock. An independent
   accounting-reviewer pass on this proc found the "byproduct/trim like
   sawdust" characterization is only PARTIALLY accurate: of the 22 rows, 12
   really are sawdust (~6.29 units), but the other 10 (~86% of this
   population's 153.45 total units) are PORK BELLY BONE IN SKINLESS / PORK
   BELLY SKIN — normal sellable cuts, not obvious trim. Why the ERP flags
   full cuts as IsStock=0 is not yet understood (quality hold? mis-tagged
   lot? sample stock?) — flagged to the developer as a follow-up, not
   resolved here. This does NOT change the filter's correctness: IsStock is
   the ERP's OWN governing classification (not invented by this proc), and
   153.45 units against ~8.9M ERP-wide on-hand units is immaterial regardless
   of what the excluded rows turn out to represent. Filtered out via
   IsStock = 1, same as every check in sql/23.

   ----------------------------------------------------------------------------
   COST DATA-QUALITY GAP — MATERIALITY RE-EXAMINED FOR THIS USE CASE, A
   MEANINGFULLY DIFFERENT PICTURE THAN sql/23's OWN 84% HEADLINE
   ----------------------------------------------------------------------------
   sql/23 reported "84% of IsStock=1 rows have Quantity > 0 AND (Cost = 0 OR
   NULL)" and flagged that as the single biggest data-quality gap in the
   Inventory pass. That 84% figure is a ROW-COUNT statistic. Re-investigated
   here at the QUANTITY/VALUE level specifically because this proc's whole
   point is a peso-value comparison, and row-count prevalence and value
   materiality are not the same thing — confirmed live, they diverge sharply:

     - ERP-wide: 6,576 of 7,812 qty>0/IsStock=1 rows (84%) are zero/null-cost
       — CONFIRMED, matches sql/23 exactly. But those 6,576 rows total only
       125,326.84 units, against a grand total of 8,939,625.40 units on-hand
       ERP-wide — 1.4% of quantity, not 84%.
     - CONFIRMED LIVE, and this is the real finding: the ENTIRE zero-cost gap
       sits in ONE branch. Every satellite branch (001 through 013) has
       ZeroCostRows = 0 — 100% cost coverage, independently confirmed per
       branch. ALL 6,576 zero-cost rows are at branch 888 (HEAD OFFICE CEBU),
       where they are 6,576 of 6,872 rows (96% of 888's ROW count) but only
       125,326.84 of 888's own 3,337,005.26 units (3.75% of 888's OWN
       quantity) — the zero-cost lots at HO are numerous but individually
       small, not the bulk of HO's physical stock either.
     - Practical read: OnHandValue for branches 001-013 is COMPLETE — every
       qty>0 lot at those branches has a real, non-zero Cost, confirmed live.
       OnHandValue for branch 888 is INCOMPLETE but not "mostly invisible" —
       roughly 96 % of 888's units are costed; a rough same-average-cost
       extrapolation over the uncosted 125,326.84 units (~PHP 129/unit
       average, from the costed population) suggests on the order of
       PHP 15-16M of additional HO value is not being counted, against an
       already-recognised HO value of PHP 414.4M — material as an absolute
       peso figure, but a low-single-digit-percent gap on HO's own total, not
       a "most of the value is invisible" situation.
     - Net conclusion, disclosed loudly as asked rather than silently baked
       into a single confident-looking total: SUM(Quantity * Cost) is NOT
       materially misleading for a branch-to-branch COMPARISON on this DEV
       data (satellite branches are fully costed; HO's gap is a few-percent
       understatement of its own already-large total, not a distortion that
       would flip which branch looks biggest) — but it is a real, non-zero
       understatement concentrated entirely at Head Office, disclosed via the
       ZeroCostQuantity/ZeroCostQuantityPct columns below rather than
       hidden inside OnHandValue, so the dashboard/consumer can render a
       caveat on 888's figure specifically instead of on every branch
       uniformly. No fallback cost source was invented — dbo.Products.
       LandingCost was already found to be 0.0000 on ALL 2,340 rows ERP-wide
       (sql/23's own finding, re-confirmed applicable here) and
       dbo.view_InventoryReport (a pre-existing, non-sp_rpt_* ERP report
       view found during this investigation) computes its own AvailableValue
       the same way — ISNULL(Cost,0) — with no alternate cost source either.
       Cost = 0/NULL is therefore contributing an honest $0 to OnHandValue on
       those specific lots, disclosed as a count/quantity alongside it, per
       the same "tautological zero is not a bug, hiding it would be" logic
       sql/23 already established for INV-ZERO-COST.

   ----------------------------------------------------------------------------
   PRIOR ART FOUND, NOT REUSED — dbo.sp_rpt_InventoryReport_Summary /
   dbo.view_InventoryReport
   ----------------------------------------------------------------------------
   A pre-existing, already-live sp_rpt_InventoryReport_Summary/_Detail pair
   and a supporting view_InventoryReport were found on CORECSERP_002_DEV
   during this investigation (OBJECT_DEFINITION() pulled and read before
   writing this script). Not reused or altered here: it is grouped by
   product/lot for a catalog-style report, not one row per branch; its
   "IsStockOnly" parameter actually filters on Available > 0 (not IsStock,
   despite the name — the IsStock predicate is present in a commented-out
   line in the view), and it values stock as Available * Cost, the opposite
   of this proc's deliberate Quantity choice above. It does not follow this
   portal's sp_rpt_Exec_* parameter shape or header conventions (no DEV/
   STAGING protocol notes, no explicit CASTs) — it appears to predate or sit
   outside this reporting portal's own build discipline. Named here so a
   future pass does not assume it is this portal's object or duplicate this
   proc's purpose by mistake.

   ----------------------------------------------------------------------------
   PARAMETERS — NONE. NO @AsOfDate. CONFIRMED, NOT ASSUMED.
   ----------------------------------------------------------------------------
   Investigated whether dbo.Inventory (or anything else) supports a genuine
   point-in-time reconstruction before defaulting to "current state only":
     - dbo.Inventory itself carries no per-row transaction/event date that
       would let a past Quantity be reconstructed (DateReceived/ExpiryDate/
       LastMovementDate describe the LOT, not a ledger of quantity changes
       over time) — confirms sql/23's characterisation of this table as a
       lot/batch-level CURRENT-state ledger, not an immutable movement log.
     - A real candidate WAS found and is worth flagging to the developer:
       dbo.InventoryEndOfDaySnapshot / dbo.InventoryEndOfDaySnapshotDetails
       — schema is exactly what a point-in-time query would want
       (SnapshotDate, Branch, Product, ClosingQuantity, ClosingAvailable,
       TotalCostValue per day). CONFIRMED LIVE: BOTH tables have ZERO rows,
       on BOTH CORECSERP_002_DEV and COREX001 (checked both as extra
       diligence since COREX001 is described elsewhere as having more
       complete data) — this looks like a designed-but-never-activated
       nightly snapshot job, not a table this proc could safely query today;
       building @AsOfDate against it would silently return nothing for
       every date, which is worse than not offering the parameter at all.
     - Conclusion: built with NO date parameter, matching the brief's
       explicit instruction for a genuinely current-state-only table rather
       than adding a fake @AsOfDate that can't actually change the answer.
       If InventoryEndOfDaySnapshot is ever populated (a nightly job start,
       or a backfill), this proc should be revisited to switch its source
       and add a real @AsOfDate — flagged for the developer, not built
       speculatively against empty tables.
     - No @BranchCodes filter either, by design and by precedent: this is a
       per-branch BREAKDOWN report (the whole point is comparing branches
       against each other), matching sp_rpt_Exec_BranchScorecard's existing
       precedent of taking no branch filter for the same reason (confirmed
       via Data/ReportRepository.cs / Services/HeyJudeService.cs comments).

   ----------------------------------------------------------------------------
   POSTED-ONLY / GL RULE — DOES NOT APPLY, SAME AS sql/23
   ----------------------------------------------------------------------------
   dbo.Inventory and dbo.Branches are not GL-posted tables; Hard Rule #1
   (Status IN ('POSTED','UPDATED')) has no analogue here. IsStock is this
   table's own governing "is this real stock" flag, used directly instead,
   same precedent sql/23 already established.
============================================================================ */


IF OBJECT_ID('dbo.sp_rpt_Exec_InventoryByBranch', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_Exec_InventoryByBranch;
GO

CREATE PROCEDURE dbo.sp_rpt_Exec_InventoryByBranch
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @AsOf datetime = SYSDATETIME();

    ;WITH OnHand AS
    (
        SELECT
            i.Branch,
            i.Quantity,
            i.Cost,
            IsZeroCost = CASE WHEN i.Cost = 0 OR i.Cost IS NULL THEN 1 ELSE 0 END
        FROM dbo.Inventory AS i
        WHERE i.Quantity > 0     -- excludes zero AND negative-quantity rows; see header
          AND i.IsStock = 1      -- excludes ERP-flagged byproduct/trim rows; see header
    )
    SELECT
        BranchCode          = CAST(b.BranchCode AS varchar(5)),
        BranchName          = CAST(b.BranchName AS varchar(128)),
        DisplayText         = CAST(b.BranchCode + '-' + ISNULL(b.BranchName, '') AS varchar(150)),
        OnHandQuantity      = CAST(ISNULL(SUM(o.Quantity), 0) AS decimal(18,3)),
        OnHandValue         = CAST(ISNULL(SUM(o.Quantity * ISNULL(o.Cost, 0)), 0) AS decimal(18,2)),
        ItemCount           = CAST(COUNT(o.Branch) AS int),
        /* Data-quality disclosure — NOT folded silently into OnHandValue.
           See header "COST DATA-QUALITY GAP". Lets the consumer render a
           caveat on the specific branch(es) affected instead of guessing. */
        ZeroCostItemCount   = CAST(ISNULL(SUM(CAST(o.IsZeroCost AS int)), 0) AS int),
        ZeroCostQuantity    = CAST(ISNULL(SUM(CASE WHEN o.IsZeroCost = 1 THEN o.Quantity END), 0) AS decimal(18,3)),
        ZeroCostQuantityPct = CAST(
                                  CASE WHEN ISNULL(SUM(o.Quantity), 0) = 0 THEN NULL
                                       ELSE ISNULL(SUM(CASE WHEN o.IsZeroCost = 1 THEN o.Quantity END), 0)
                                            * 100.0 / SUM(o.Quantity)
                                  END AS decimal(9,4)),
        AsOf                = CAST(@AsOf AS datetime)
    FROM dbo.Branches AS b
    LEFT JOIN OnHand AS o ON o.Branch = b.BranchCode
    GROUP BY b.BranchCode, b.BranchName
    ORDER BY OnHandValue DESC;
END
GO


/* ============================================================================
   SMOKE TEST
============================================================================ */
/*
EXEC dbo.sp_rpt_Exec_InventoryByBranch;
*/
