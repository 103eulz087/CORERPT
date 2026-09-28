/* ============================================================================
   CORE REPORTING PORTAL — EXCEPTION CENTER (Build Order Step 1)
   Target: CORECSERP_002_DEV only (never staging without asking).

   Scope of THIS script: the config-driven architecture itself, plus the
   Segregation of Duties category — same preparer/approver only.
   After-hours postings was investigated and is NOT built here; see the
   "AFTER-HOURS POSTINGS — NOT BUILDABLE" note below for why, per the brief's
   explicit instruction to name a check that can't be built rather than
   silently skip it.

   This module is distinct from dbo.sp_rpt_DataHealthCheck: that proc verifies
   ledger math ties out (does the GL balance, subledger vs control). This
   module detects business-process red flags — skipped controls, override
   patterns — using the SAME result shape (CheckName/Severity/Findings/
   ValueAtRisk pattern) and the same summary+detail two-proc split, so the
   existing Health Check UI component can be pointed at this data source
   later without a rebuild.

   ----------------------------------------------------------------------------
   REVISION 2026-09-23 — accounting-reviewer pass over live CORECSERP_002_DEV
   found one material bug and one documentation gap in the original version of
   this script. Both are fixed here, in place, on the SAME two procs (renamed
   to *_OLD_20260923 below rather than dropped, per DB change protocol):
     1. ValueAtRisk join fallback + BranchCodeMismatch flag — see the
        "DATA-QUALITY FINDING" note below and the methodology comment inside
        sp_rpt_ExceptionCenter_Summary.
     2. ValueAtRisk methodology comment corrected from "SUM(Debit) is a sound
        value-at-risk because it equals SUM(Credit)" (incomplete — that only
        proves footing, not net exposure) — see the same methodology comment.
   No detection logic (which tickets get flagged) changed. Only how a flagged
   ticket's ValueAtRisk is computed, and what is shown in the drilldown.
   ----------------------------------------------------------------------------

   ----------------------------------------------------------------------------
   SCHEMA CONFIRMED LIVE ON CORECSERP_002_DEV BEFORE WRITING THIS (2026-09-23)
   ----------------------------------------------------------------------------
   dbo.TicketMaster:  TicketDate datetime, SupplementaryNumber tinyint,
     BranchCode varchar(5), Origin varchar(10), TicketNumber varchar(50),
     ReferenceNumber varchar(150), ReferenceKey varchar(150), Owner varchar(150),
     Particulars varchar(7000), EnteredBy varchar(128), CheckedBy varchar(128),
     ApprovedBy varchar(128), Status varchar(50), Mnemonic varchar(50),
     Product varchar(530).
   dbo.TicketDetails: TicketDate datetime, SupplementaryNumber tinyint,
     BranchCode varchar(5), ReferenceKey varchar(50), TicketNumber varchar(50),
     ReferenceNumber varchar(50), AccountCode varchar(20), Debit money
     (NOT NULL), Credit money (NOT NULL), CostCenter varchar(10),
     Particulars varchar(400).
   dbo.Branches: BranchCode varchar, BranchName varchar, Address varchar,
     SignatoryManager varchar, SignatoryCashier varchar.

   ----------------------------------------------------------------------------
   DATA-QUALITY FINDING — READ BEFORE TRUSTING THIS CHECK'S COUNTS
   ----------------------------------------------------------------------------
   Queried live: of 2,406 POSTED/UPDATED TicketMaster rows, CheckedBy and
   ApprovedBy are the literal sentinel string '*' on 2,405 of them. Only ONE
   row carries a real (non-'*', non-NULL) value in either column: TicketNumber
   '1', BranchCode = '' (blank — confirmed the ONLY row in all of TicketMaster
   with a blank BranchCode), Mnemonic = '*', EnteredBy/CheckedBy/ApprovedBy all
   'system', dated 2026-07-31. It looks like a bootstrap/opening-balance
   placeholder header, not a real user transaction.

   REVISED 2026-09-23 (accounting-reviewer pass) — this header is NOT an
   orphan; the original version of this script was wrong to call it one.
   TicketNumber '1' has 831 real TicketDetails lines, fully balanced
   (SUM(Debit) = SUM(Credit) = 3,688,581,595.84), spread across 14 real
   branch codes ('001'-'013','888'). The header's own BranchCode ('') simply
   does not match ANY of its own detail lines' BranchCodes, so the standard
   strict 4-column join (TicketDate + SupplementaryNumber + BranchCode +
   TicketNumber) — which is correct and REQUIRED for the normal case, see the
   methodology comment inside sp_rpt_ExceptionCenter_Summary below — correctly
   finds zero matching rows for this one header. That is a genuine
   data-integrity defect on this single bootstrap ticket (a blank header
   BranchCode), not a bug in how the join was written.

   Both procs below now retry with a narrower TicketDate + SupplementaryNumber
   + TicketNumber key (BranchCode dropped) ONLY when the strict join finds
   zero rows for a header, and expose a BranchCodeMismatch flag in the detail
   result set so a reviewer sees the header/detail disagreement explicitly
   rather than a silently "corrected" number. A true orphan (zero detail rows
   under EITHER key) still reports NULL ValueAtRisk. This blank-BranchCode
   header is a data-integrity item worth flagging to the developer to fix at
   the source in TicketMaster — a reporting proc working around it is not the
   same as it being fixed.

   CONCLUSION: the checking/approval workflow columns exist and are wired
   correctly in the schema, but this ERP's real posting flows do not currently
   populate CheckedBy/ApprovedBy with actual reviewer usernames — everything
   defaults to '*'. That means, as written, this check will find ~0 genuine
   findings against current DEV data, NOT because segregation of duties is
   being followed, but because the checking/approval step isn't captured at
   all yet. That is a bigger business-process gap than "same person twice" and
   is worth flagging to the developer separately — it is outside this check's
   job (which is literally "same person in 2+ fields"), so it is reported here
   rather than silently built around.

   DESIGN DECISION — '*' is treated as "no value", same as NULL, and excluded
   from the equality comparison via NULLIF(col, '*'). Comparing '*' = '*'
   literally would flag all 2,405 sentinel rows as "same preparer/approver",
   which is 100% noise, not signal — exactly the "present but wrong" failure
   CLAUDE.md warns about. Only a match on a REAL username counts.

   KNOWN EDGE CASE, no code change made (carried forward from reviewer pass):
   NULLIF(col,'*') only strips the exact literal '*'. Confirmed 0 rows today
   have '' (empty string) in EnteredBy/CheckedBy/ApprovedBy, so there is no
   current false-positive risk — but if the sentinel convention ever drifts to
   include '', two blank rows would compare '' = '' and wrongly flag as a
   match. Revisit (e.g. NULLIF(NULLIF(col,'*'),'')) if that ever appears live.

   ----------------------------------------------------------------------------
   AFTER-HOURS POSTINGS — NOT BUILDABLE, NOT BUILT (per brief's explicit
   instruction: name it, don't silently skip it)
   ----------------------------------------------------------------------------
   Investigated: TicketMaster.TicketDate is `datetime` (8 bytes, so it CAN
   carry a time component), but live data shows 2,393 of 2,407 rows (99.4%)
   are stored at exactly 00:00:00 — date-only in practice. Only 14 rows carry
   a genuine time-of-day, and every one of them is either Mnemonic
   'CONV-FINALIZE' (a single conversion-finalize flow, entered by one user,
   'Lorenzo Jesus Del Rio', spanning 2026-09-10 to 2026-09-23) or a single
   REVERSED-status row. TicketDetails has no timestamp column at all, and
   neither TicketMaster nor TicketDetails has a CreatedDate/DateTimeAdded-style
   audit column.
   Other tables DO carry a genuine created-at timestamp — PaymentHeader.
   CreatedDate, ExpenseSummary.DateTimeAdded/DateTimeUpdated, TransferBatch.
   CreatedAt (datetime2), BankReconHeader.CreatedDate — but none of them
   carries a confirmed join key back to TicketMaster's natural key
   (TicketDate, SupplementaryNumber, BranchCode, TicketNumber), and
   discovering/confirming that join belongs to the Vouchering/Post Expense/
   Inventory categories explicitly deferred to later build-order steps, not
   this Segregation-of-Duties pass.
   CONCLUSION: an after-hours check built on TicketMaster.TicketDate today
   would cover 0.6% of postings (one narrow module, one user) and silently
   imply the other 99.4% of the ledger has no after-hours activity, which is
   false — it's simply unmeasured. That is worse than not having the check.
   NOT BUILT. No ExceptionDefinition row is seeded for it. Revisit once a
   genuine per-ticket entry timestamp exists in the posting chain, or once a
   confirmed join from PaymentHeader/ExpenseSummary/TransferBatch back to
   TicketMaster is established in a later build-order step.

   ----------------------------------------------------------------------------
   SEVERITY DECISION — Critical (documented per developer's ask to justify)
   ----------------------------------------------------------------------------
   One ExceptionCode covers all three pairwise collisions (Entered=Checked,
   Entered=Approved, Checked=Approved) rather than splitting into three codes,
   mirroring sp_rpt_DataHealthCheck's one-row-per-check-name pattern. Severity
   is set to Critical for the whole code, not split Warning/Critical per pair,
   because: (a) a Checked=Approved collision on its own already means the
   ticket had a SINGLE independent reviewer, not two, before it hit the books
   — the same practical failure as no review at all; (b) given the sentinel-'*'
   finding above, a genuine (non-'*') match in this data is rare enough by
   construction that it is very unlikely to be innocuous test noise — it is
   far more likely a deliberate or misconfigured override; (c) the detail proc
   (below) still reports a MatchType per row (which specific fields collided),
   so a reviewer triaging the drill-down can visually deprioritize an
   Entered=Checked-only row versus an Approved-involved row without needing a
   second exception code in this first pass.
============================================================================ */


/* ============================================================================
   1. dbo.ExceptionDefinition — config-driven metadata table
   Seeded ONLY with exception codes actually implemented in this pass.
   Unchanged by this revision — no DDL change needed here.
============================================================================ */
IF OBJECT_ID('dbo.ExceptionDefinition', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ExceptionDefinition
    (
        ExceptionCode   varchar(50)  NOT NULL CONSTRAINT PK_ExceptionDefinition PRIMARY KEY,
        Category        varchar(50)  NOT NULL,
        Title           varchar(200) NOT NULL,
        Severity        varchar(10)  NOT NULL
            CONSTRAINT CK_ExceptionDefinition_Severity
            CHECK (Severity IN ('Critical','Warning','Info')),
        HasDrillDown    bit          NOT NULL CONSTRAINT DF_ExceptionDefinition_HasDrillDown DEFAULT (0),
        DrillDownRoute  varchar(200) NULL,
        IsActive        bit          NOT NULL CONSTRAINT DF_ExceptionDefinition_IsActive DEFAULT (1),
        SortOrder       int          NOT NULL CONSTRAINT DF_ExceptionDefinition_SortOrder DEFAULT (100)
    );
END
GO

/* Seed — ONLY the checks built in this pass. Config-driven means the next
   category is just an INSERT here plus a branch in the two procs below;
   do NOT pre-seed rows for checks that don't have logic behind them yet. */
MERGE dbo.ExceptionDefinition AS tgt
USING (VALUES
    ('SOD-SAME-PREP-APPR', 'Segregation of Duties', 'Same preparer/approver on a ticket',
     'Critical', 1, '/ExceptionCenter/Detail?code=SOD-SAME-PREP-APPR', 10)
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
   2. dbo.sp_rpt_ExceptionCenter_Summary — the aggregator
   One row per exception CURRENTLY implemented, joined to ExceptionDefinition.
   Follows sp_rpt_DataHealthCheck's precedent: detection logic inline via a
   #Result temp table, UNION-style (one INSERT block per check), not farmed
   out to per-check procs — same pattern, same reasons (single date-window
   scope, single transaction, easy to read top-to-bottom).

   DB change protocol: this proc already exists in DEV. Per CLAUDE.md /
   db-change-protocol, the previous (buggy ValueAtRisk) definition is
   preserved under an _OLD_<timestamp> name rather than dropped outright, so
   it stays queryable for audit/rollback. This is a fix to the SAME object,
   not a new one — see accounting-reviewer Finding 1/2, REVISION note above.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary_OLD_20260923;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Summary', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Summary', 'sp_rpt_ExceptionCenter_Summary_OLD_20260923';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Summary
    @DateFrom date,
    @DateTo   date
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));
    DECLARE @AsOf  datetime = GETDATE();

    CREATE TABLE #Result
    (
        ExceptionCode varchar(50) NOT NULL,
        Findings      int         NOT NULL,
        ValueAtRisk   money       NULL
    );

    /* ---- SOD-SAME-PREP-APPR: same real user in 2+ of Entered/Checked/Approved ----
       '*' is a sentinel meaning "no checker/approver captured", not a value
       that can collide with itself — see header note. NULLIF() strips it out
       (and NULLs) before comparing, so only genuine username matches count.

       ValueAtRisk = SUM of each flagged ticket's gross debit footing
       (SUM(Debit) per ticket). This is GROSS TICKET FOOTING, not a measure of
       net economic exposure — it only proves the ticket balances
       (SUM(Debit) = SUM(Credit) for a balanced posted ticket), nothing more.
       Hard Rule #5's Nature-signed convention doesn't reduce to one number
       for a ticket spanning many accounts of mixed Nature, so gross debit
       total is used instead, deliberately not attempting a Nature-signed net
       across unrelated accounts.
       CONFIRMED COUNTER-EXAMPLE (accounting-reviewer pass, 2026-09-23):
       TicketNumber 7338, a CONV-FINALIZE reclassification with offsetting
       legs on two accounts, has SUM(Debit) = SUM(Credit) = 22,539.19
       (perfectly balanced) while its real net reclassification is only
       1,818.81 — about 12x smaller. That ticket is not currently flagged
       here (the '*' sentinel excludes it), so today's number is not
       corrupted by this, but do NOT re-derive "SUM(Debit) = real exposure"
       confidence from "it equals SUM(Credit)" — that only proves footing
       balance, not net risk, and could mislead on a future genuine
       reclassification-style collision.

       Detail rows for a flagged header are located with the standard strict
       4-column key (TicketDate + SupplementaryNumber + BranchCode +
       TicketNumber) — this is correct and REQUIRED for the normal case:
       cross-branch tickets in this system are one-header-per-branch, each
       with its own correctly-populated BranchCode, balanced across headers
       via shared ReferenceNumber per Hard Rule #6. Dropping BranchCode from
       the join in general would risk fan-out/cross-contamination for those.
       If — and only if — the strict join finds zero rows for a header, a
       narrower fallback key (TicketDate + SupplementaryNumber +
       TicketNumber, BranchCode dropped) is tried before concluding a true
       orphan. This is a narrow, documented fallback for one confirmed data
       defect (blank-BranchCode header on TicketNumber '1' — see header
       note), NOT a general relaxation of the join. True orphans (no rows
       under either key) still contribute NULL/0. Debit is NOT NULL on
       TicketDetails, so SUM(Debit) over zero matching rows is NULL and over
       any real rows is never NULL (even if it happens to sum to 0), which is
       what makes "strict sum IS NULL" a safe test for "no matching rows". */
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

    /* ---- Future checks land here as additional INSERT blocks, each adding
       one ExceptionCode already present in ExceptionDefinition. ---- */

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
   3. dbo.sp_rpt_ExceptionCenter_Detail — generic drilldown
   Parameterized by @ExceptionCode, branching on it exactly like
   sp_rpt_DataHealthCheckDetail branches on @Seq — different result columns
   per code is the accepted, already-precedented shape in this codebase.

   DB change protocol: same treatment as the Summary proc above — previous
   definition preserved under _OLD_20260923 rather than dropped.
============================================================================ */
IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail_OLD_20260923;
GO

IF OBJECT_ID('dbo.sp_rpt_ExceptionCenter_Detail', 'P') IS NOT NULL
    EXEC sp_rename 'dbo.sp_rpt_ExceptionCenter_Detail', 'sp_rpt_ExceptionCenter_Detail_OLD_20260923';
GO

CREATE PROCEDURE dbo.sp_rpt_ExceptionCenter_Detail
    @ExceptionCode varchar(50),
    @DateFrom      date,
    @DateTo        date
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Start datetime = CAST(@DateFrom AS datetime);
    DECLARE @End   datetime = DATEADD(DAY, 1, CAST(@DateTo AS datetime));

    /* ==== SOD-SAME-PREP-APPR — one row per flagged ticket, with MatchType ==== */
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
            /* TicketValue = gross ticket footing (SUM(Debit)), NOT net economic
               exposure — see the methodology comment in
               sp_rpt_ExceptionCenter_Summary. Strict join first
               (TicketDate+SupplementaryNumber+BranchCode+TicketNumber); if
               that finds zero rows, fall back to dropping BranchCode from the
               key. BranchCodeMismatch = 1 means the fallback was needed —
               i.e. this header's own BranchCode did not match its own detail
               lines' BranchCodes — surfaced here as an explicit flag, not a
               silent correction, so a reviewer can see why. */
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

    /* ==== Unknown @ExceptionCode — fail loudly, matching sp_rpt_DataHealthCheckDetail ==== */
    RAISERROR('sp_rpt_ExceptionCenter_Detail: unknown or not-yet-implemented @ExceptionCode ''%s''.', 16, 1, @ExceptionCode);
END
GO


/* ============================================================================
   SMOKE TEST
============================================================================ */
/*
DECLARE @From date = '2020-01-01', @To date = '2026-12-31';

EXEC dbo.sp_rpt_ExceptionCenter_Summary @DateFrom = @From, @DateTo = @To;
-- Expect: SOD-SAME-PREP-APPR, Findings = 1,
--         ValueAtRisk = 3688581595.84 (TicketNumber '1', post-fix).

EXEC dbo.sp_rpt_ExceptionCenter_Detail
     @ExceptionCode = 'SOD-SAME-PREP-APPR', @DateFrom = @From, @DateTo = @To;
-- Expect: one row, TicketNumber '1', BranchCode = '', TicketValue = 3688581595.84,
--         BranchCodeMismatch = 1 (strict join found 0 rows under BranchCode='',
--         fallback found 831 rows across 14 real branches).

-- Fails loudly, does not silently return empty:
-- EXEC dbo.sp_rpt_ExceptionCenter_Detail @ExceptionCode = 'NOT-A-REAL-CODE', @DateFrom = @From, @DateTo = @To;
*/
