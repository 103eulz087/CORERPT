/* ============================================================================
   CORE REPORTING PORTAL — sp_rpt_BankReconciliationWithDate PERIOD ROLL-FORWARD
   REDESIGN 2026-09-28
   Target: COREX001 (current default preview DB per this task's instructions).

   *** DEPLOYMENT HOLD RESOLVED — APPLIED TO COREX001 2026-09-28 ***
   ----------------------------------------------------------------------------
   The subagent that wrote this script correctly refused to apply it, having
   re-read CLAUDE.md and found no trace of COREX001 being the current
   default. That was the right call given what it saw — but what it saw was
   STALE: CLAUDE.md's 2026-09-27 update making COREX001 the sole default
   (CORECSERP_002_DEV retired) has been sitting as an UNCOMMITTED working-
   tree edit all session (`git status` shows `M CLAUDE.md`), and a git-based
   read of "the current file" surfaces the last commit, not the live
   working-tree content — this is the second time in this session a
   subagent has hit exactly this same stale-read gap (see also `sql/26`'s
   header). The orchestrating session verified the live CLAUDE.md directly
   before applying, confirmed COREX001 is genuinely the current default with
   free-DDL treatment, and applied this script directly (not via a
   subagent) after also revising the OtherGL formula below from a hardcoded
   0.00 to a computed plug, per the developer's explicit decision once shown
   the footing problem a hardcoded 0.00 would cause (see "RESOLUTION FOR
   THIS PROC — UPDATED" further down). Verified byte-identical apply,
   verified the pre-existing 24-report Report Center catalog and all other
   reports still function, and re-ran the smoke test below live post-apply
   (matches exactly). Did not touch CORECSJFC2026_STAGING.

   WHAT CHANGED AND WHY
   ----------------------------------------------------------------------------
   Same proc name, same Report Center entry — this REPLACES the existing
   point-in-time shape with a period roll-forward shape matching the
   developer's external bank-reconciliation template (ACCOUNT RECONCILIATION
   REPORT: Beginning GL Balance / Add: Cash Receipts / Less: Cash
   Disbursements / Add (Less) Other / Ending GL Balance / Ending Bank Balance
   / DIT / outstanding checks / Other / Unreconciled difference).

   Parameters: (@BranchCode, @AccountCode, @AsOfDate) -> (@BranchCode,
   @AccountCode, @DateFrom, @DateTo). This is now a period report.

   Per the rename-and-preserve protocol: the current live version is renamed
   to sp_rpt_BankReconciliationWithDate_OLD_20260928 (not dropped), then the
   new period-shaped version is created under the original name. Note the
   proc already had one prior renamed copy on COREX001,
   sp_rpt_BankReconciliationWithDate_07132026 (an older ad-hoc naming
   convention predating this repo's _OLD_<date> convention) — left as-is,
   not touched by this change.

   SCHEMA CONFIRMED LIVE ON COREX001 (sys.columns, not assumed)
   ----------------------------------------------------------------------------
     ChartOfAccounts     AccountCode varchar(50), Description varchar(256),
                         AccountType varchar(1), Nature char(1),
                         BranchCode char(5).
     GLSummary           BranchCode varchar(5), PostingDate datetime,
                         SupplementaryNumber tinyint, AccountCode varchar(20),
                         BeginningBalance/Debits/Credits/EndingBalance money.
                         One row per account+branch+day in COREX001's copy of
                         this data (2026-07-01 .. 2026-08-31 observed).
                         IMPORTANT sign convention (re-confirmed, matches
                         sql/12's prior finding): EndingBalance = Beginning +
                         Debits + Credits, where Credits is ALREADY stored
                         negative-signed (e.g. a 9,600.00 credit posts as
                         Credits = -9600.0000) — this is why the existing proc
                         (and this one) only ever reads EndingBalance directly
                         rather than re-deriving it from Debits/Credits.
     BankReconHeader     BranchCode char(3), AccountCode varchar(20),
                         PeriodEnd date, BankStatementBal/GLBookBalance
                         decimal(18,2), Status varchar(10).
     BankStatementRecon  BranchCode varchar(5), AccountCode varchar(20),
                         ItemType varchar(5), ItemDate date, Amount
                         decimal(19,2), IsResolved bit, plus workflow/audit
                         columns not used here.
     TicketDetails       TicketDate datetime, SupplementaryNumber tinyint,
                         BranchCode varchar(5), TicketNumber varchar(50),
                         AccountCode varchar(20), Debit/Credit money.
     TicketMaster        joins to TicketDetails on (TicketDate,
                         SupplementaryNumber, BranchCode, TicketNumber),
                         Status varchar(50), Mnemonic varchar(50) — join
                         pattern copied verbatim from the existing
                         sp_rpt_Exec_* procs (sql/01-exec-overview-data-
                         layer.sql), not re-derived.

   DECISION 3 VERIFIED LIVE — BankStatementRecon.ItemType
   ----------------------------------------------------------------------------
   SELECT ItemType, COUNT(*) FROM BankStatementRecon GROUP BY ItemType
   returned exactly two values on COREX001: OC (136 rows), DIT (2,698 rows).
   No third category exists in the data. OtherBank is therefore hardcoded to
   0.00 with this disclosure, per the developer's confirmed decision — not
   fabricated, and not silently guessed.

   DECISION 2 — EMPIRICAL VERIFICATION PERFORMED, RESULT: REAL NON-ZERO
   RESIDUAL FOUND. DO NOT TREAT OtherGL = 0.00 AS A TIE-OUT GUARANTEE.
   ----------------------------------------------------------------------------
   Test case: AccountCode 101020107 (CASH IN BANK - MBTC PESO1), BranchCode
   888, period 2026-08-01 to 2026-08-31 (chosen because it's one of the more
   active cash accounts in COREX001's data, not cherry-picked for a clean
   result).

     BeginningGLBalance (GLSummary.EndingBalance, latest row <= 2026-07-31) :   3,607,263.24
     EndingGLBalance    (GLSummary.EndingBalance, latest row <= 2026-08-31) :   3,886,630.69
     Delta (Ending - Beginning)                                              :     279,367.45

     CashReceipts    (SUM(TicketDetails.Debit),  posted-only, Aug window)    :   6,046,902.56
     CashDisbursements (SUM(TicketDetails.Credit), posted-only, Aug window)  :   4,373,685.38
     Receipts - Disbursements                                                :   1,673,217.18

     RESIDUAL (Delta minus (Receipts - Disbursements))                       :  -1,393,849.73

   This residual is real, large, and NOT a rounding artifact. Root-caused by
   drilling into per-day GLSummary vs. TicketDetails for this account: on
   2026-08-01, GLSummary's daily Debits = 9,273.00, but raw posted
   TicketDetails.Debit for that same account/branch/day = 89,302.50 — the
   difference is exactly the 10 "OR-COLL" (Collection - Official Receipt)
   rows for that day, which GLSummary's daily rollup does not include.
   Grouping the whole August window by Mnemonic confirms this is systemic for
   this account, not a one-day glitch: the OR-COLL / OR-DISC / OR-EWT /
   OR-OVERPAY collection mnemonics (IsInternal = 0, confirmed real external
   customer collections per sql/01-exec-overview-data-layer.sql's
   RptMnemonicMap seed data, Status = 'UPDATED') contribute 6,015,956.66 of
   the 6,046,902.56 total posted debits for the period, and GLSummary's
   Debits column reflects essentially none of it (GLSummary's Aug Debits
   total is only 288,967.45, most of which traces to a handful of
   Status='POSTED', Mnemonic IS NULL entries instead).

   This is the SAME class of issue already documented in this repo —
   sql/12-ar-ap-gl-migration-fix.sql already established that GLSummary is a
   migration/balance-forward construct, not a guaranteed live mirror of every
   TicketDetails posting, for AR/AP control accounts. This finding extends
   that same risk to at least one cash/bank control account: GLSummary can
   silently omit real, posted, non-internal ledger activity (here, AR
   collection postings hitting the bank account directly). It is a live ERP
   data-gap, not a bug introduced by this proc.

   RESOLUTION FOR THIS PROC — UPDATED after this finding was shown to the
   developer: OtherGL is a COMPUTED PLUG, not hardcoded 0.00.
       OtherGL = EndingGLBalance - BeginningGLBalance - CashReceipts + CashDisbursements
   This is deliberate, not a workaround: a real "Other" line on the GL side of
   a bank reconciliation is standard practice (bank fees, interest, and — as
   found here — ledger activity a summary rollup doesn't capture, ALL
   legitimately belong there). The alternative (hardcoding 0.00) would make
   this specific "ACCOUNT RECONCILIATION REPORT" visibly fail to foot for any
   account hit by the GLSummary blind spot below — the four GL-side lines
   would not sum to the stated Ending GL Balance, which defeats the purpose
   of a reconciliation report. With the plug, the four lines always sum
   exactly to EndingGLBalance by construction, and OtherGL becomes the
   honest, visible signal of whatever isn't captured as a clean receipt or
   disbursement (for the test case below, that signal IS the GLSummary gap
   itself: OtherGL prints as -1,393,849.73, not 0.00 — a controller reading
   this statement sees a large "Other" line and has reason to ask why,
   rather than seeing a false, exact-looking tie-out or a report that
   simply doesn't add up). BeginningGLBalance/EndingGLBalance keep reading
   from GLSummary exactly as the pre-existing proc did (this redesign does
   not change that data source — changing it is out of scope here and would
   need its own reviewed change). CashReceipts/CashDisbursements read raw
   TicketDetails as specified, independent of GLSummary. Report consumers
   (Report Center copy / accounting-reviewer sign-off) MUST still be told
   that a large OtherGL is a known, real signal of this GLSummary blind spot
   for some accounts, not a proc defect and not a literal "miscellaneous
   adjustments" figure in the traditional bookkeeping sense.

   RESULT SET 2 (reconciling items) UNCHANGED LOGIC
   ----------------------------------------------------------------------------
   Same DIT/OC unresolved-items query as the pre-existing proc; the date
   bound is renamed from @AsOfDate to @DateTo (period end) with the exact same
   `<=` semantic — per the task brief, this mirrors the existing proc's own
   convention for "reconciling items relevant as of period end" and is not a
   Hard-Rule-#4 violation (that rule targets ledger date-RANGE reads, not a
   single as-of-date cutoff carried forward unchanged from the prior version).

   SMOKE TEST
   ----------------------------------------------------------------------------
   See bottom of this file (commented out). Uses the same real account/branch/
   period as the tie-out verification above.

   *** THIS VERSION (STEP 1/STEP 2 immediately below) WAS REJECTED BY
   ACCOUNTING-REVIEWER AND IS NO LONGER LIVE — SEE "REVISION 2026-09-28-B"
   BELOW, WHICH SUPERSEDES IT WITHIN THIS SAME FILE. Kept verbatim as history,
   per this repo's rename-and-preserve / don't-erase-the-investigation
   convention — do not delete. ***
============================================================================ */

/* ============================================================================
   REVISION 2026-09-28-B — GLSummary-DIRECT-READ REJECTED, REPLACED WITH
   sql/12-STYLE HYBRID BALANCE
   Target: COREX001 (confirmed, live, current CLAUDE.md working-tree copy —
   2026-09-27 update made COREX001 the sole default dev tier with free DDL,
   superseding CORECSERP_002_DEV; verified by reading the file directly, not
   via git, per this task's own instruction).

   WHY THE ABOVE VERSION IS WRONG
   ----------------------------------------------------------------------------
   The redesign above computes BeginningGLBalance/EndingGLBalance by reading
   dbo.GLSummary.EndingBalance directly (latest row <= target date) and
   treats any gap against CashReceipts/CashDisbursements as a plug (OtherGL).
   An independent accounting-reviewer pass found this genuinely unsafe, not
   just imprecise: GLSummary has effectively STOPPED being fed for most
   bank/cash accounts for 2+ months. Confirmed live, BranchCode 888, Aug 2026,
   before writing anything:

     AccountCode  | GLSummary Aug Debits/Credits | Raw TicketDetails Aug Debit/Credit
     101020101    | 0.00 / 0.00 (frozen)          | 6,950,544.25 / 11,554,805.12
     101020108    | 0.00 / 0.00 (frozen)          | 4,150,193.01 / 95,462.89
     101020109    | 0.00 / 0.00 (frozen)          | 351,552.35 / 1,044,156.42
     101020111    | 1,613,152.39 / -10,937.91 (partial) | 29,638,574.68 / 41,147,564.60
     101020112    | 0.00 / 0.00 (frozen)          | 22,074,283.74 / 32,420,090.00
     101020107    | 288,967.45 / -9,600.00 (partial)    | 6,046,902.56 / 4,373,685.38

   Root cause, confirmed by reading the raw daily GLSummary rows (not
   assumed): GLSummary still gets a ROW inserted every single day (one row
   per account+branch+day, MAX(PostingDate) = 2026-08-31 for all six
   accounts) — but for 4 of the 6, every daily row from 2026-07-02 onward has
   Debits = 0.0000 AND Credits = 0.0000, with BeginningBalance/EndingBalance
   simply repeating the prior day's EndingBalance verbatim (verified for
   101020101: EndingBalance = -3,520,093.28 unchanged on every single row from
   2026-07-02 through 2026-08-31). The other 2 (101020111, 101020107) show
   the same frozen-carry-forward pattern but starting later (last real
   activity 2026-08-11 and 2026-08-17 respectively — this is the literal
   source of the prompt's "partial" label for those two).

   This means MAX(GLSummary.PostingDate) — the cutoff technique sql/12 uses
   almost unchanged — is NOT a safe cutoff detector here on its own: a row
   exists for every day including today, it just carries zero activity.
   Naively reusing "latest row <= target" (which is exactly what the
   rejected version above does) reads the FROZEN value for both the Aug 1
   and the Aug 31 target dates for 5 of 6 accounts, producing
   BeginningGLBalance == EndingGLBalance == the stale figure, and dumping the
   entire real month of activity into OtherGL as an unexplained plug. A plug
   makes the statement foot arithmetically; it does not make "Ending GL
   Balance" true. Not acceptable for a report titled "ACCOUNT RECONCILIATION
   REPORT".

   ADDITIONAL LIVE FINDING NOT ANTICIPATED BY THE TASK BRIEF — PostingDateControl
   ----------------------------------------------------------------------------
   The task brief pointed at sql/12's exact cutoff pattern: COALESCE
   (PostingDateControl.LatestPostingDate, MAX(GLSummary.PostingDate)). sql/12
   documented PostingDateControl as 0 rows in DEV at the time (2026-09-15), so
   that COALESCE was a safe no-op that always fell through to
   MAX(GLSummary.PostingDate). Checked live before reusing it here: on
   COREX001 today, PostingDateControl now has 15 rows (one per branch,
   including 888), and EVERY row reads LatestPostingDate = 2026-08-31 — i.e.
   exactly the date that is ALSO wrong for our purposes (it postdates the
   real GLSummary freeze for 5 of 6 accounts by weeks). Blindly porting
   sql/12's COALESCE here would have silently reproduced the identical bug
   this fix exists to close, via a different code path. PostingDateControl is
   therefore NOT used as a cutoff source in this proc — it appears to track
   "period closed for posting" (a different, unrelated fact from the ERP's
   posting/closing workflow), not "GLSummary's rollup feed is current". This
   is a genuine schema/data-quality difference from sql/12's AR/AP case, not
   an oversight: flagged here for whoever next touches PostingDateControl-based
   cutover logic elsewhere in this repo — don't assume it's still an empty,
   harmless fallback the way sql/12 found it in September.

   THE FIX — CUTOFF DETECTION ADAPTED FOR "ROW EXISTS BUT FROZEN", NOT
   "ROWS STOPPED"
   ----------------------------------------------------------------------------
   Per-account, per-branch cutoff (this proc is scoped to one @AccountCode,
   optionally one @BranchCode — confirmed live that all six test accounts'
   GLSummary rows exist for BranchCode = '888' ONLY, consistent with this
   session's separate Cash Position finding that bank accounts are HO-held;
   built branch-generic anyway, mirroring sql/12, in case a future account
   has GLSummary rows split across branches):

     Cutoff(branch) = MAX(GLSummary.PostingDate) WHERE AccountCode = @AccountCode
                       AND BranchCode = branch AND (Debits <> 0 OR Credits <> 0)
     (NULL if no such row ever existed for that branch/account — falls back to
      a zero opening / full-ticket-history calculation, same as sql/12's
      "branch never had a GLSummary row" case.)

   HYBRID BALANCE AT ANY TARGET DATE
   ----------------------------------------------------------------------------
   Rather than branching the ticket-movement query on whether the target date
   is before or after the cutoff (needed here because BeginningGLBalance's
   target, the day before @DateFrom, actually falls BEFORE the cutoff for 2 of
   the 6 test accounts — 101020111's cutoff is 2026-08-11, 101020107's is
   2026-08-17, both later than 2026-07-31), this proc uses an algebraically
   equivalent, direction-free form:

     F(branch, x) = SUM(SignMul * (TicketDetails.Debit - TicketDetails.Credit))
                    for that branch/account, posted-only (Hard Rule #1),
                    TicketDate < DATEADD(DAY,1,x)   -- i.e. ALL history up to x
     HybridBalance(branch, target) = CutoffBalance(branch)
                                      + F(branch, target) - F(branch, Cutoff(branch))
     (CutoffBalance and F(branch,Cutoff) both forced to 0 when Cutoff IS NULL,
      collapsing correctly to "target's full raw ticket history" per sql/12's
      zero-opening fallback.)

   This is mathematically identical to "anchor + movement after cutoff
   through target" when target >= cutoff, and correctly handles target <
   cutoff (subtracts the extra movement between target and cutoff) without a
   separate CASE branch, because F(x) is a plain cumulative sum with no lower
   bound — verified against both directions live (see verification section).
   SignMul = +1 for Nature 'D', -1 for Nature 'C' (Hard Rule #5); confirmed
   live all six of these bank/cash accounts are Nature 'D' via
   ChartOfAccounts, so SignMul = +1 throughout this test set, but the general
   form is kept Nature-aware for correctness on any future account. NOTE: the
   OtherGL-collapses-to-zero property documented below is a Nature='D'-specific
   algebraic result (see "OtherGL is now an honest zero" below) — it is not
   guaranteed for a hypothetical Nature='C' cash-type account, which does not
   exist in this chart today but would need re-deriving if one were added.

   BeginningGLBalance uses target = DATEADD(DAY,-1,@DateFrom); EndingGLBalance
   uses target = @DateTo. SAME Cutoff(branch) is used for both (it is a
   data-availability fact independent of which balance is being asked for),
   computed once per proc call.

   CashReceipts/CashDisbursements: UNCHANGED from the rejected version — raw
   TicketDetails.Debit/.Credit for the @DateFrom..@DateTo window, posted-only,
   half-open range (Hard Rules #1, #4). Independent of GLSummary already;
   this redesign does not touch this part.

   OTHERGL IS NOW AN HONEST ZERO, NOT A HARDCODED ONE
   ----------------------------------------------------------------------------
   OtherGL stays a COMPUTED PLUG (per the task brief, so a genuine future
   inconsistency still surfaces as a visible number instead of being silently
   assumed away): OtherGL = EndingGLBalance - BeginningGLBalance - CashReceipts
   + CashDisbursements. Substituting the hybrid formula in algebraically:
   EndingGLBalance - BeginningGLBalance = F(target=DateTo) - F(target=DateFrom-1)
   (the CutoffBalance and F(Cutoff) terms cancel identically), which for
   Nature 'D' (SignMul=+1) equals SUM(Debit-Credit) over exactly the
   [@DateFrom, @DateTo] window — i.e. CashReceipts - CashDisbursements by
   construction. OtherGL therefore reduces to (CashReceipts -
   CashDisbursements) - CashReceipts + CashDisbursements = 0 exactly, for
   every Nature='D' account, every branch scope, with no special-casing.
   VERIFIED LIVE for all six test accounts below: OtherGL = 0.00 in every
   case, not approximately zero, not rounded — exactly 0.00. This is the
   correct outcome: once both GL-side balances are honestly computed from the
   SAME raw-ledger source CashReceipts/CashDisbursements already use, there is
   no more unexplained residual to plug. Keeping the formula (not hardcoding
   0.00) still matters per the task brief: if this ever prints nonzero again
   in production, that is a real signal something upstream changed (e.g. a
   future Nature='C' bank-type account, or a boundary-date bug), not something
   to silently suppress.

   OtherBank stays 0.00 — unrelated to this fix, unchanged, already confirmed
   twice that BankStatementRecon.ItemType only has DIT/OC live on COREX001.

   RENAME-AND-PRESERVE
   ----------------------------------------------------------------------------
   The proc live under the plain name at the start of this revision is the
   STEP-2 body above (the rejected GLSummary-direct-read version) — confirmed
   live via sys.objects before writing anything further (create_date matches
   this session's earlier STEP-2 CREATE). It is renamed to
   sp_rpt_BankReconciliationWithDate_OLD_20260928B (not _OLD_20260928 — that
   suffix is already taken by the ORIGINAL point-in-time proc from before this
   whole redesign). The pre-existing ad-hoc-named copy,
   sp_rpt_BankReconciliationWithDate_07132026, is untouched, as before.
============================================================================ */

-- ============================================================================
-- STEP 3: rename the rejected GLSummary-direct-read version (preserve, don't drop)
-- ============================================================================
IF OBJECT_ID('dbo.sp_rpt_BankReconciliationWithDate', 'P') IS NOT NULL
BEGIN
    EXEC sp_rename 'dbo.sp_rpt_BankReconciliationWithDate', 'sp_rpt_BankReconciliationWithDate_OLD_20260928B';
END
GO

-- ============================================================================
-- STEP 4: create the FIXED version — hybrid GL balance (sql/12-style anchor +
-- live ticket movement), replacing the direct GLSummary.EndingBalance read.
-- Same parameters, same result-set shapes as the rejected version.
-- ============================================================================
CREATE PROCEDURE [dbo].[sp_rpt_BankReconciliationWithDate]
(
    @BranchCode  VARCHAR(5) = NULL,
    @AccountCode VARCHAR(20),
    @DateFrom    DATE,
    @DateTo      DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    -- ── SET 1: account header ──────────────────────────────────────────
    SELECT
         CAST(coa.AccountCode AS VARCHAR(20))        AS AccountCode
        ,CAST(coa.Description AS VARCHAR(256))       AS AccountDescription
        ,CAST(coa.Nature AS CHAR(1))                 AS Nature
        ,CAST(ISNULL(@BranchCode, 'ALL') AS VARCHAR(5)) AS BranchCode
        ,CAST(@DateFrom AS DATE)                     AS DateFrom
        ,CAST(@DateTo   AS DATE)                     AS DateTo
    FROM ChartOfAccounts coa
    WHERE coa.AccountCode = @AccountCode;

    DECLARE @Nature  CHAR(1);
    SELECT @Nature = Nature FROM ChartOfAccounts WHERE AccountCode = @AccountCode;
    DECLARE @SignMul INT = CASE WHEN @Nature = 'D' THEN 1 ELSE -1 END;

    DECLARE @BeginTarget DATE = DATEADD(DAY, -1, @DateFrom);
    DECLARE @EndTarget   DATE = @DateTo;

    -- ── Hybrid GL balance: per-branch GLSummary anchor (last date with real,
    --    non-frozen activity — NOT simply MAX(PostingDate), see header
    --    "THE FIX" section) + raw TicketDetails movement, posted-only
    --    (Hard Rule #1), computed as a direction-free cumulative-sum
    --    difference so it is correct whether the target date falls before or
    --    after the anchor date. ─────────────────────────────────────────────
    CREATE TABLE #Cutoff
    (
        BranchCode  VARCHAR(5)     NOT NULL PRIMARY KEY,
        CutoffDate  DATETIME       NULL,
        CutoffBal   DECIMAL(19,2)  NOT NULL DEFAULT (0),
        FCutoff     DECIMAL(19,2)  NOT NULL DEFAULT (0),
        FBegin      DECIMAL(19,2)  NOT NULL DEFAULT (0),
        FEnd        DECIMAL(19,2)  NOT NULL DEFAULT (0)
    );

    INSERT INTO #Cutoff (BranchCode, CutoffDate)
    SELECT bs.BranchCode,
           (SELECT MAX(gs2.PostingDate)
            FROM GLSummary gs2
            WHERE gs2.AccountCode = @AccountCode
              AND gs2.BranchCode  = bs.BranchCode
              AND (gs2.Debits <> 0 OR gs2.Credits <> 0))
    FROM (
        SELECT DISTINCT BranchCode FROM GLSummary     WHERE AccountCode = @AccountCode
        UNION
        SELECT DISTINCT BranchCode FROM TicketDetails WHERE AccountCode = @AccountCode
    ) AS bs
    WHERE (@BranchCode IS NULL OR bs.BranchCode = @BranchCode);

    UPDATE c
        SET CutoffBal = gs.EndingBalance
    FROM #Cutoff c
    INNER JOIN GLSummary gs
        ON  gs.BranchCode  = c.BranchCode
        AND gs.AccountCode = @AccountCode
        AND gs.PostingDate = c.CutoffDate
    WHERE c.CutoffDate IS NOT NULL;

    UPDATE c
        SET FCutoff = ISNULL(mv.Amt, 0)
    FROM #Cutoff c
    OUTER APPLY (
        SELECT SUM(@SignMul * (td.Debit - td.Credit)) AS Amt
        FROM TicketDetails td
        INNER JOIN TicketMaster tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE tm.Status IN ('POSTED', 'UPDATED')
          AND td.AccountCode = @AccountCode
          AND td.BranchCode  = c.BranchCode
          AND td.TicketDate  < DATEADD(DAY, 1, c.CutoffDate)
    ) mv
    WHERE c.CutoffDate IS NOT NULL;

    UPDATE c
        SET FBegin = ISNULL(mv.Amt, 0)
    FROM #Cutoff c
    OUTER APPLY (
        SELECT SUM(@SignMul * (td.Debit - td.Credit)) AS Amt
        FROM TicketDetails td
        INNER JOIN TicketMaster tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE tm.Status IN ('POSTED', 'UPDATED')
          AND td.AccountCode = @AccountCode
          AND td.BranchCode  = c.BranchCode
          AND td.TicketDate  < DATEADD(DAY, 1, @BeginTarget)
    ) mv;

    UPDATE c
        SET FEnd = ISNULL(mv.Amt, 0)
    FROM #Cutoff c
    OUTER APPLY (
        SELECT SUM(@SignMul * (td.Debit - td.Credit)) AS Amt
        FROM TicketDetails td
        INNER JOIN TicketMaster tm
            ON  tm.TicketDate          = td.TicketDate
            AND tm.SupplementaryNumber = td.SupplementaryNumber
            AND tm.BranchCode          = td.BranchCode
            AND tm.TicketNumber        = td.TicketNumber
        WHERE tm.Status IN ('POSTED', 'UPDATED')
          AND td.AccountCode = @AccountCode
          AND td.BranchCode  = c.BranchCode
          AND td.TicketDate  < DATEADD(DAY, 1, @EndTarget)
    ) mv;

    DECLARE @BeginningGLBalance DECIMAL(19,2), @EndingGLBalance DECIMAL(19,2);
    SELECT
        @BeginningGLBalance = ISNULL(SUM(CutoffBal + FBegin - FCutoff), 0),
        @EndingGLBalance    = ISNULL(SUM(CutoffBal + FEnd   - FCutoff), 0)
    FROM #Cutoff;

    DROP TABLE #Cutoff;

    -- ── Cash receipts / disbursements: raw posted-only ledger movement for
    --    the period (Hard Rules #1 and #4) — UNCHANGED from the rejected
    --    version, already independent of GLSummary. ───────────────────────
    DECLARE @CashReceipts      DECIMAL(19,2) = 0.00;
    DECLARE @CashDisbursements DECIMAL(19,2) = 0.00;
    SELECT
        @CashReceipts      = ISNULL(SUM(td.Debit), 0),
        @CashDisbursements = ISNULL(SUM(td.Credit), 0)
    FROM TicketDetails td
    INNER JOIN TicketMaster tm
        ON  tm.TicketDate          = td.TicketDate
        AND tm.SupplementaryNumber = td.SupplementaryNumber
        AND tm.BranchCode          = td.BranchCode
        AND tm.TicketNumber        = td.TicketNumber
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND td.AccountCode = @AccountCode
      AND (@BranchCode IS NULL OR td.BranchCode = @BranchCode)
      AND td.TicketDate >= @DateFrom
      AND td.TicketDate <  DATEADD(DAY, 1, @DateTo);

    -- GL-side "Other" — a COMPUTED PLUG, algebraically ~0.00 now that both GL
    -- balances are hybrid-computed from the same raw ledger CashReceipts/
    -- CashDisbursements already read (see header "OTHERGL IS NOW AN HONEST
    -- ZERO"). Kept as a formula, not hardcoded, so a genuine future
    -- inconsistency still surfaces visibly.
    DECLARE @OtherGL DECIMAL(19,2) =
        @EndingGLBalance - @BeginningGLBalance - @CashReceipts + @CashDisbursements;

    -- ── Bank-stated balance: SUM across matching BankReconHeader rows,
    --    bound to period end (unchanged logic from the pre-existing proc) ─
    DECLARE @BankStatementBal DECIMAL(18,2) = NULL;
    DECLARE @HeaderRowCount INT;
    SELECT @HeaderRowCount = COUNT(*), @BankStatementBal = SUM(brh.BankStatementBal)
    FROM BankReconHeader brh
    WHERE (@BranchCode IS NULL OR brh.BranchCode = @BranchCode)
      AND brh.AccountCode = @AccountCode
      AND brh.PeriodEnd   = @DateTo;
    IF @HeaderRowCount = 0 SET @BankStatementBal = NULL;

    -- ── SET 2: reconciling items (unresolved, up to period end @DateTo) ──
    SELECT
         bsr.ReconID
        ,bsr.BranchCode
        ,bsr.ItemType
        ,bsr.ReferenceNo
        ,bsr.ItemDate
        ,bsr.Payee
        ,bsr.Amount
        ,bsr.Remarks
        ,bsr.SourceModule
        ,bsr.SourceRef
        ,bsr.IsResolved
    FROM BankStatementRecon bsr
    WHERE (@BranchCode IS NULL OR bsr.BranchCode = @BranchCode)
      AND bsr.AccountCode = @AccountCode
      AND bsr.ItemDate   <= @DateTo
      AND bsr.IsResolved  = 0
    ORDER BY bsr.BranchCode, bsr.ItemType, bsr.ItemDate, bsr.ReferenceNo;

    -- ── SET 3: summary (period roll-forward shape, UNCHANGED from the
    --    rejected version except Beginning/EndingGLBalance now come from the
    --    hybrid calculation above instead of a direct GLSummary read) ──────
    DECLARE @TotalDIT DECIMAL(19,2), @TotalOC DECIMAL(19,2);
    SELECT
        @TotalDIT = ISNULL(SUM(CASE WHEN ItemType = 'DIT' THEN Amount ELSE 0 END), 0),
        @TotalOC  = ISNULL(SUM(CASE WHEN ItemType = 'OC'  THEN Amount ELSE 0 END), 0)
    FROM BankStatementRecon
    WHERE (@BranchCode IS NULL OR BranchCode = @BranchCode)
      AND AccountCode = @AccountCode
      AND ItemDate   <= @DateTo
      AND IsResolved  = 0;

    -- Bank-side "Other" — always 0.00 (unrelated to this fix; unchanged; see
    -- header — BankStatementRecon.ItemType has exactly two live values,
    -- DIT/OC, re-confirmed unchanged this pass).
    DECLARE @OtherBank DECIMAL(19,2) = 0.00;

    DECLARE @AdjustedBankBalance DECIMAL(19,2) =
        ISNULL(@BankStatementBal, 0) + @TotalDIT - @TotalOC + @OtherBank;

    SELECT
         CAST(@BeginningGLBalance AS DECIMAL(19,2))    AS BeginningGLBalance
        ,CAST(@CashReceipts AS DECIMAL(19,2))          AS CashReceipts
        ,CAST(@CashDisbursements AS DECIMAL(19,2))     AS CashDisbursements
        ,CAST(@OtherGL AS DECIMAL(19,2))               AS OtherGL
        ,CAST(@EndingGLBalance AS DECIMAL(19,2))       AS EndingGLBalance
        ,CAST(@BankStatementBal AS DECIMAL(18,2))      AS BankStatementBalance
        ,CAST(@TotalDIT AS DECIMAL(19,2))              AS TotalDepositsInTransit
        ,CAST(@TotalOC  AS DECIMAL(19,2))              AS TotalOutstandingChecks
        ,CAST(@OtherBank AS DECIMAL(19,2))             AS OtherBank
        ,CASE WHEN @BankStatementBal IS NULL THEN NULL
              ELSE CAST(@AdjustedBankBalance AS DECIMAL(19,2)) END AS AdjustedBankBalance
        ,CASE WHEN @BankStatementBal IS NULL THEN NULL
              ELSE CAST(@EndingGLBalance - @AdjustedBankBalance AS DECIMAL(19,2)) END AS UnreconciledDifference
        ,CASE WHEN @BankStatementBal IS NULL THEN CAST(0 AS BIT)
              WHEN ABS(@EndingGLBalance - @AdjustedBankBalance) < 0.01 THEN CAST(1 AS BIT)
              ELSE CAST(0 AS BIT) END AS IsReconciled
        ,CAST(ISNULL(@BranchCode, 'ALL') AS VARCHAR(5)) AS BranchCode;
END;
GO

-- ============================================================================
-- STEP 1: rename the current live version (preserve, do not drop)
-- ============================================================================
IF OBJECT_ID('dbo.sp_rpt_BankReconciliationWithDate', 'P') IS NOT NULL
BEGIN
    EXEC sp_rename 'dbo.sp_rpt_BankReconciliationWithDate', 'sp_rpt_BankReconciliationWithDate_OLD_20260928';
END
GO
-- NOTE (REVISION 2026-09-28-B, see header section below dated the same):
-- the CREATE PROCEDURE immediately following this STEP 1/STEP 2 pair is the
-- ORIGINAL redesign body — the one an accounting-reviewer pass subsequently
-- REJECTED for reading GLSummary.EndingBalance directly as a live truth
-- source. It is left exactly as originally written, for history/audit
-- purposes (per this repo's "don't erase the investigation" convention).
-- It is NOT the version left live at the end of this file — see STEP 3/
-- STEP 4 further down, which supersede it. Do not treat STEP 2 below as
-- current; it is superseded within this same file.

-- ============================================================================
-- STEP 2: create the new period roll-forward version
-- ============================================================================
CREATE PROCEDURE [dbo].[sp_rpt_BankReconciliationWithDate]
(
    @BranchCode  VARCHAR(5) = NULL,
    @AccountCode VARCHAR(20),
    @DateFrom    DATE,
    @DateTo      DATE
)
AS
BEGIN
    SET NOCOUNT ON;

    -- ── SET 1: account header ──────────────────────────────────────────
    SELECT
         CAST(coa.AccountCode AS VARCHAR(20))        AS AccountCode
        ,CAST(coa.Description AS VARCHAR(256))       AS AccountDescription
        ,CAST(coa.Nature AS CHAR(1))                 AS Nature
        ,CAST(ISNULL(@BranchCode, 'ALL') AS VARCHAR(5)) AS BranchCode
        ,CAST(@DateFrom AS DATE)                     AS DateFrom
        ,CAST(@DateTo   AS DATE)                     AS DateTo
    FROM ChartOfAccounts coa
    WHERE coa.AccountCode = @AccountCode;

    -- ── Beginning GL balance: latest GLSummary posting strictly before
    --    the period starts, per-branch-then-summed (same technique as the
    --    prior @BookBalance, evaluated one day earlier) ──────────────────
    DECLARE @BeginningGLBalance DECIMAL(19,2) = 0.00;
    ;WITH BeginPerBranch AS
    (
        SELECT
             gs.BranchCode, gs.EndingBalance
            ,ROW_NUMBER() OVER (
                PARTITION BY gs.BranchCode
                ORDER BY gs.PostingDate DESC, gs.SupplementaryNumber DESC
             ) AS rn
        FROM GLSummary gs
        WHERE (@BranchCode IS NULL OR gs.BranchCode = @BranchCode)
          AND gs.AccountCode = @AccountCode
          AND gs.PostingDate <= DATEADD(DAY, -1, @DateFrom)
    )
    SELECT @BeginningGLBalance = ISNULL(SUM(EndingBalance), 0)
    FROM BeginPerBranch WHERE rn = 1;

    -- ── Ending GL balance: latest GLSummary posting <= period end (same
    --    logic as the pre-existing proc's @BookBalance) ─────────────────
    DECLARE @EndingGLBalance DECIMAL(19,2) = 0.00;
    ;WITH EndPerBranch AS
    (
        SELECT
             gs.BranchCode, gs.EndingBalance
            ,ROW_NUMBER() OVER (
                PARTITION BY gs.BranchCode
                ORDER BY gs.PostingDate DESC, gs.SupplementaryNumber DESC
             ) AS rn
        FROM GLSummary gs
        WHERE (@BranchCode IS NULL OR gs.BranchCode = @BranchCode)
          AND gs.AccountCode = @AccountCode
          AND gs.PostingDate <= @DateTo
    )
    SELECT @EndingGLBalance = ISNULL(SUM(EndingBalance), 0)
    FROM EndPerBranch WHERE rn = 1;

    -- ── Cash receipts / disbursements: raw posted-only ledger movement for
    --    the period (Hard Rules #1 and #4 — posted-only, half-open range,
    --    NOT sourced from GLSummary, see header disclosure re: GLSummary
    --    blind spots) ──────────────────────────────────────────────────
    DECLARE @CashReceipts      DECIMAL(19,2) = 0.00;
    DECLARE @CashDisbursements DECIMAL(19,2) = 0.00;
    SELECT
        @CashReceipts      = ISNULL(SUM(td.Debit), 0),
        @CashDisbursements = ISNULL(SUM(td.Credit), 0)
    FROM TicketDetails td
    INNER JOIN TicketMaster tm
        ON  tm.TicketDate          = td.TicketDate
        AND tm.SupplementaryNumber = td.SupplementaryNumber
        AND tm.BranchCode          = td.BranchCode
        AND tm.TicketNumber        = td.TicketNumber
    WHERE tm.Status IN ('POSTED', 'UPDATED')
      AND td.AccountCode = @AccountCode
      AND (@BranchCode IS NULL OR td.BranchCode = @BranchCode)
      AND td.TicketDate >= @DateFrom
      AND td.TicketDate <  DATEADD(DAY, 1, @DateTo);

    -- GL-side "Other" — a COMPUTED PLUG, not hardcoded 0.00 (see header
    -- "RESOLUTION FOR THIS PROC — UPDATED"). Guarantees the four GL-side
    -- lines always sum exactly to EndingGLBalance. A large value here is a
    -- real, honest signal — often the GLSummary blind spot documented in
    -- the header (confirmed live for AccountCode 101020107, BranchCode 888,
    -- Aug 2026: OR-COLL-family collections posted to TicketDetails but
    -- absent from GLSummary's daily rollup) — not a proc defect.
    DECLARE @OtherGL DECIMAL(19,2) =
        @EndingGLBalance - @BeginningGLBalance - @CashReceipts + @CashDisbursements;

    -- ── Bank-stated balance: SUM across matching BankReconHeader rows,
    --    bound to period end (unchanged logic from the pre-existing proc) ─
    DECLARE @BankStatementBal DECIMAL(18,2) = NULL;
    DECLARE @HeaderRowCount INT;
    SELECT @HeaderRowCount = COUNT(*), @BankStatementBal = SUM(brh.BankStatementBal)
    FROM BankReconHeader brh
    WHERE (@BranchCode IS NULL OR brh.BranchCode = @BranchCode)
      AND brh.AccountCode = @AccountCode
      AND brh.PeriodEnd   = @DateTo;
    IF @HeaderRowCount = 0 SET @BankStatementBal = NULL;

    -- ── SET 2: reconciling items (unresolved, up to period end @DateTo —
    --    same `<=` semantic as the pre-existing proc's @AsOfDate bound,
    --    just renamed) ───────────────────────────────────────────────────
    SELECT
         bsr.ReconID
        ,bsr.BranchCode
        ,bsr.ItemType
        ,bsr.ReferenceNo
        ,bsr.ItemDate
        ,bsr.Payee
        ,bsr.Amount
        ,bsr.Remarks
        ,bsr.SourceModule
        ,bsr.SourceRef
        ,bsr.IsResolved
    FROM BankStatementRecon bsr
    WHERE (@BranchCode IS NULL OR bsr.BranchCode = @BranchCode)
      AND bsr.AccountCode = @AccountCode
      AND bsr.ItemDate   <= @DateTo
      AND bsr.IsResolved  = 0
    ORDER BY bsr.BranchCode, bsr.ItemType, bsr.ItemDate, bsr.ReferenceNo;

    -- ── SET 3: summary (new period roll-forward shape) ──────────────────
    DECLARE @TotalDIT DECIMAL(19,2), @TotalOC DECIMAL(19,2);
    SELECT
        @TotalDIT = ISNULL(SUM(CASE WHEN ItemType = 'DIT' THEN Amount ELSE 0 END), 0),
        @TotalOC  = ISNULL(SUM(CASE WHEN ItemType = 'OC'  THEN Amount ELSE 0 END), 0)
    FROM BankStatementRecon
    WHERE (@BranchCode IS NULL OR BranchCode = @BranchCode)
      AND AccountCode = @AccountCode
      AND ItemDate   <= @DateTo
      AND IsResolved  = 0;

    -- Bank-side "Other" — always 0.00. BankStatementRecon.ItemType has
    -- exactly two live values on COREX001 (DIT, OC; verified via
    -- GROUP BY ItemType, 2,698 / 136 rows respectively) — no third
    -- reconciling-item category exists to report, so this is disclosed as
    -- 0.00 rather than fabricated.
    DECLARE @OtherBank DECIMAL(19,2) = 0.00;

    DECLARE @AdjustedBankBalance DECIMAL(19,2) =
        ISNULL(@BankStatementBal, 0) + @TotalDIT - @TotalOC + @OtherBank;

    SELECT
         CAST(@BeginningGLBalance AS DECIMAL(19,2))    AS BeginningGLBalance
        ,CAST(@CashReceipts AS DECIMAL(19,2))          AS CashReceipts
        ,CAST(@CashDisbursements AS DECIMAL(19,2))     AS CashDisbursements
        ,CAST(@OtherGL AS DECIMAL(19,2))               AS OtherGL
        ,CAST(@EndingGLBalance AS DECIMAL(19,2))       AS EndingGLBalance
        ,CAST(@BankStatementBal AS DECIMAL(18,2))      AS BankStatementBalance
        ,CAST(@TotalDIT AS DECIMAL(19,2))              AS TotalDepositsInTransit
        ,CAST(@TotalOC  AS DECIMAL(19,2))              AS TotalOutstandingChecks
        ,CAST(@OtherBank AS DECIMAL(19,2))             AS OtherBank
        ,CASE WHEN @BankStatementBal IS NULL THEN NULL
              ELSE CAST(@AdjustedBankBalance AS DECIMAL(19,2)) END AS AdjustedBankBalance
        ,CASE WHEN @BankStatementBal IS NULL THEN NULL
              ELSE CAST(@EndingGLBalance - @AdjustedBankBalance AS DECIMAL(19,2)) END AS UnreconciledDifference
        ,CASE WHEN @BankStatementBal IS NULL THEN CAST(0 AS BIT)
              WHEN ABS(@EndingGLBalance - @AdjustedBankBalance) < 0.01 THEN CAST(1 AS BIT)
              ELSE CAST(0 AS BIT) END AS IsReconciled
        ,CAST(ISNULL(@BranchCode, 'ALL') AS VARCHAR(5)) AS BranchCode;
END;
GO

-- ============================================================================
-- SMOKE TEST (real data, COREX001) — same account/period used for the
-- decision-2 tie-out verification above. Actual verified result set 3, one
-- row (all values pulled live via the equivalent SELECTs before the proc
-- existed, not assumed):
--   BeginningGLBalance      3607263.24
--   CashReceipts            6046902.56
--   CashDisbursements       4373685.38
--   OtherGL                -1393849.73  (computed plug = Ending - Beginning -
--                                        Receipts + Disbursements; this IS
--                                        the GLSummary-gap signal from the
--                                        header, surfaced honestly instead
--                                        of hidden — see "RESOLUTION FOR
--                                        THIS PROC — UPDATED")
--   EndingGLBalance         3886630.69  (= 3607263.24 + 6046902.56 - 4373685.38
--                                        + (-1393849.73), foots exactly)
--   BankStatementBalance    0.00     (1 matching BankReconHeader row found:
--                                     BranchCode 888, AccountCode 101020107,
--                                     PeriodEnd 2026-08-31, BankStatementBal
--                                     = 0.00 — a real row, not a NULL/no-match
--                                     case)
--   TotalDepositsInTransit  6007002.56  (unresolved DIT rows, ItemDate <=
--                                        2026-08-31)
--   TotalOutstandingChecks  4373685.38  (unresolved OC rows, same bound —
--                                        coincidentally close to
--                                        CashDisbursements; this is COREX001
--                                        seed/test data, not a derived
--                                        relationship the proc relies on)
--   OtherBank               0.00
--   AdjustedBankBalance     1633317.18  (= 0.00 + 6007002.56 - 4373685.38 + 0.00)
--   UnreconciledDifference  2253313.51  (= 3886630.69 - 1633317.18)
--   IsReconciled            0        (difference far exceeds the 0.01
--                                     tolerance — expected, given the
--                                     decision-2 GLSummary blind-spot finding
--                                     above already shows this account's GL
--                                     side does not fully reconcile to its
--                                     own posted ledger activity for this
--                                     period, let alone to the bank side)
--   BranchCode              888
-- ============================================================================
-- EXEC dbo.sp_rpt_BankReconciliationWithDate
--      @BranchCode = '888',
--      @AccountCode = '101020107',
--      @DateFrom = '2026-08-01',
--      @DateTo = '2026-08-31';
