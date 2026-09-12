/* ============================================================================
   CORE REPORTING PORTAL — TICKET DRILLDOWN
   sp_rpt_TicketDrilldown — read-only replacement for the ERP-internal
   dbo.sp_GetTicketDetailsByTicketNumber, called from the GL Detail
   Transaction Report when a user clicks a detail row to see that ticket's
   full header + all GL legs.

   Target:     CORECSERP_002_DEV only. Do NOT apply to CORECSJFC2026_STAGING
               without asking first (db-change-protocol).

   WHY NOT REUSE dbo.sp_GetTicketDetailsByTicketNumber DIRECTLY
   --------------------------------------------------------------------------
   Investigated against CORECSERP_002_DEV on 2026-09-12. That proc:
     1. Has NO `TicketMaster.Status IN ('POSTED','UPDATED')` filter at all
        (Hard Rule #1 violation) — it would happily show a draft/void ticket.
     2. Is not in the sp_rpt_* namespace, so it is not covered by the
        rpt_reader login's EXECUTE grants (see DEPLOYMENT.md) — calling it
        from the portal would be a deployment blocker, not just a style
        issue.
     3. Its `TOP 1 ... WHERE TicketNumber = @TicketNumber` header pattern,
        and its legs query filtering TicketDetails by TicketNumber alone,
        both silently assume TicketNumber is globally unique. Verified
        against current data (2,255 rows in TicketMaster, 2,255 distinct
        TicketNumber values, zero collisions) — true today, but TicketNumber
        is NOT the declared key. TicketMaster's real primary key is the
        4-part natural key (TicketDate, SupplementaryNumber, BranchCode,
        TicketNumber). Relying on global TicketNumber uniqueness as a
        permanent assumption is exactly the kind of thing that bites this
        ERP later (cf. the BranchCode-as-int bugs already on record).

   This proc mirrors the reference proc's two-result-set shape (header, then
   legs) but fixes both issues: adds the posted-only filter, and scopes the
   legs query to the exact ticket found in the header via the full natural
   key, not TicketNumber alone.

   SCHEMA NOTE / DEVIATION FROM THE ASK
   --------------------------------------------------------------------------
   The task suggested `@TicketNumber varchar(20)`, matching the reference
   proc's parameter. Checked the actual column: TicketMaster.TicketNumber
   and TicketDetails.TicketNumber are both `varchar(50)`. Both this proc and
   the reference proc's varchar(20) parameter would silently truncate/miss
   any future ticket number longer than 20 chars before it ever reaches the
   WHERE clause. Using varchar(50) here to match the real column width —
   flagging this as a latent bug in the reference proc, not carrying it
   forward.

   CONVENTIONS (see 01-exec-overview-data-layer.sql)
   --------------------------------------------------------------------------
   Posted rows      TicketMaster.Status IN ('POSTED','UPDATED')
   Natural key join TicketDate + SupplementaryNumber + BranchCode +
                     TicketNumber (TicketMaster's real PK) — never
                     TicketNumber alone.
   Branch codes     ALWAYS varchar. Never converted to int.
   Signed amount    Nature 'D' -> Debit - Credit; Nature 'C' -> Credit - Debit.
   Every result column explicit CAST for a stable ADO.NET reader contract.

   This proc only SELECTs. No base table is written.
============================================================================ */

IF OBJECT_ID('dbo.sp_rpt_TicketDrilldown', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_TicketDrilldown;
GO

CREATE PROCEDURE dbo.sp_rpt_TicketDrilldown
    @TicketNumber varchar(50)
AS
BEGIN
    SET NOCOUNT ON;

    /* Resolve the header once into a working table variable. TOP 1 with a
       deterministic ORDER BY is a defensive measure, not an endorsement of
       "TicketNumber is globally unique forever" — if that ever stops being
       true, this proc still returns exactly one ticket instead of an
       ambiguous set, and the natural key captured here (not TicketNumber
       alone) is what scopes the legs query below. */
    DECLARE @Ticket TABLE
    (
        TicketDate          datetime      NOT NULL,
        SupplementaryNumber tinyint       NOT NULL,
        BranchCode          varchar(5)    NOT NULL,
        TicketNumber        varchar(50)   NOT NULL,
        ReferenceNumber     varchar(150)  NULL,
        ReferenceKey        varchar(150)  NULL,
        Origin              varchar(10)   NULL,
        Mnemonic            varchar(50)   NULL,
        Remarks             varchar(7000) NULL,
        Owner               varchar(150)  NULL,
        EnteredBy           varchar(128)  NULL,
        CheckedBy           varchar(128)  NULL,
        ApprovedBy          varchar(128)  NULL,
        Status              varchar(50)   NULL
    );

    INSERT INTO @Ticket
    SELECT TOP 1
        tm.TicketDate, tm.SupplementaryNumber, tm.BranchCode, tm.TicketNumber,
        tm.ReferenceNumber, tm.ReferenceKey, tm.Origin, tm.Mnemonic,
        tm.Particulars, tm.Owner, tm.EnteredBy, tm.CheckedBy, tm.ApprovedBy,
        tm.Status
    FROM dbo.TicketMaster AS tm
    WHERE tm.TicketNumber = @TicketNumber
      AND tm.Status IN ('POSTED', 'UPDATED')   -- Hard Rule 1: posted rows only
    ORDER BY tm.TicketDate DESC, tm.BranchCode, tm.SupplementaryNumber;

    /* ---- Result set 1: ticket header -------------------------------------
       Zero rows if @TicketNumber does not exist, or exists only as a
       draft/void ticket (Status not in POSTED/UPDATED). That is deliberate:
       every other figure in this portal is posted-only, so a drilldown must
       not be the one place that leaks an unposted ticket. */
    SELECT
        TicketNumber        = CAST(TicketNumber AS varchar(50)),
        TicketDate          = CAST(TicketDate AS datetime),
        SupplementaryNumber = CAST(SupplementaryNumber AS tinyint),
        BranchCode          = CAST(BranchCode AS varchar(5)),
        ReferenceNumber     = CAST(ReferenceNumber AS varchar(150)),
        ReferenceKey        = CAST(ReferenceKey AS varchar(150)),
        Origin               = CAST(Origin AS varchar(10)),
        Mnemonic             = CAST(Mnemonic AS varchar(50)),
        Remarks              = CAST(Remarks AS varchar(7000)),
        Owner                = CAST(Owner AS varchar(150)),
        EnteredBy            = CAST(EnteredBy AS varchar(128)),
        CheckedBy            = CAST(CheckedBy AS varchar(128)),
        ApprovedBy           = CAST(ApprovedBy AS varchar(128)),
        Status               = CAST(Status AS varchar(50))
    FROM @Ticket;

    /* ---- Result set 2: GL legs --------------------------------------------
       Joined to TicketMaster via the full natural key (TicketDate +
       SupplementaryNumber + BranchCode + TicketNumber) — the same pattern
       used by the Position/Movement CTEs in 01-exec-overview-data-layer.sql
       — so these legs are scoped to the exact posted ticket resolved above,
       never to "any TicketDetails row that happens to share this
       TicketNumber". If @Ticket is empty (no posted match), this join
       naturally returns zero rows too. */
    SELECT
        AccountCode     = CAST(td.AccountCode AS varchar(20)),
        AccountTitle    = CAST(coa.Description AS varchar(256)),
        Nature          = CAST(coa.Nature AS char(1)),
        Debit           = CAST(td.Debit AS money),
        Credit          = CAST(td.Credit AS money),
        SignedAmount    = CAST(CASE coa.Nature
                                    WHEN 'D' THEN td.Debit - td.Credit
                                    ELSE          td.Credit - td.Debit
                                END AS money),
        BranchCode      = CAST(td.BranchCode AS varchar(5)),
        ReferenceKey    = CAST(td.ReferenceKey AS varchar(50)),
        ReferenceNumber = CAST(td.ReferenceNumber AS varchar(50)),
        CostCenter      = CAST(td.CostCenter AS varchar(10)),
        Particulars     = CAST(td.Particulars AS varchar(400))
    FROM dbo.TicketDetails AS td
    INNER JOIN @Ticket AS t
        ON  t.TicketDate          = td.TicketDate
        AND t.SupplementaryNumber = td.SupplementaryNumber
        AND t.BranchCode          = td.BranchCode
        AND t.TicketNumber        = td.TicketNumber
    LEFT JOIN dbo.ChartOfAccounts AS coa
        ON coa.AccountCode = td.AccountCode
    ORDER BY td.Debit DESC, td.Credit DESC;
END
GO


/* ============================================================================
   SMOKE TEST
   Ticket 7039 and 7041 — branch 888, account 101040102, dated 2026-09-12,
   Status = POSTED, Mnemonic = IT-HO-VATEX (an internal inventory transfer;
   note it will not appear in consolidated sales/COGS per Hard Rule 7 — that
   exclusion belongs to sp_rpt_GLDetailTransactionReport, not this proc,
   since this proc's job is just "show me this one ticket").
============================================================================ */
/*
EXEC dbo.sp_rpt_TicketDrilldown @TicketNumber = '7039';
EXEC dbo.sp_rpt_TicketDrilldown @TicketNumber = '7041';

-- Non-existent / unposted ticket number -> both result sets empty, zero rows
EXEC dbo.sp_rpt_TicketDrilldown @TicketNumber = '999999999';

-- Balance check: legs must sum Debit = Credit per ticket (double-entry)
SELECT TicketNumber, SUM(Debit) AS TotalDebit, SUM(Credit) AS TotalCredit
FROM dbo.TicketDetails WHERE TicketNumber IN ('7039','7041')
GROUP BY TicketNumber;
*/
