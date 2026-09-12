namespace CoreReporting.Models;

/* ============================================================================
   PART B — Report Center

   A config-driven engine over 7 existing, confirmed-working sp_rpt_* procs.
   These are NOT re-derived DTOs per report: the whole point is one generic
   Grid/Statement/PivotStatement renderer, so the repository reads result
   sets generically (column name + a light type tag + row values) instead of
   one strongly-typed row class per proc.
============================================================================ */

public enum ReportRenderStyle
{
    Grid,
    Statement,
    PivotStatement
}

/// <summary>
/// Which parameters a report declares. A report can combine flags (e.g.
/// DateRange | Branch | Account for the GL detail reports). AsOfDate and
/// DateRange are mutually exclusive in practice (each proc takes one or the
/// other) but both are represented so the parameter bar knows which date
/// control(s) to show.
/// </summary>
[Flags]
public enum ReportParameterKind
{
    None = 0,
    AsOfDate = 1,
    DateRange = 2,
    Branch = 4,
    Account = 8
}

/// <summary>
/// One entry per Report Center proc. Static/seeded — see <see cref="ReportCatalog"/>.
/// </summary>
public sealed class ReportDefinition
{
    public required string ProcName { get; init; }
    public required string Title { get; init; }
    public required string Description { get; init; }
    public required string Category { get; init; }
    public required ReportRenderStyle RenderStyle { get; init; }
    public required ReportParameterKind Parameters { get; init; }

    /// <summary>
    /// True for the two reports where @AccountCode has no "all accounts"
    /// mode (GLDetailLedgerWithDate, BankReconciliationWithDate) — a real
    /// account code is mandatory, never DBNull.Value.
    /// </summary>
    public bool AccountRequired { get; init; }

    /// <summary>
    /// True for sp_rpt_GLDetailTransactionReport and the two "Live" financial
    /// statement procs (sp_rpt_BalanceSheetLiveWithDate,
    /// sp_rpt_IncomeStatementLiveWithDate), all of which have an
    /// @IncludeZeroActivity bit parameter the parameter bar should surface
    /// as a checkbox.
    /// </summary>
    public bool SupportsIncludeZeroActivity { get; init; }

    /// <summary>
    /// True only for the two "Live" financial statement procs
    /// (sp_rpt_BalanceSheetLiveWithDate, sp_rpt_IncomeStatementLiveWithDate),
    /// which have a required @IncludeLiveActivity bit parameter the parameter
    /// bar should surface as a checkbox, defaulted to checked (true) — the
    /// whole point of picking the Live report over its non-Live sibling is
    /// seeing unposted current-period activity, but an explicit false gives
    /// the tie-out/audit view (posted GLSummary only).
    /// </summary>
    public bool SupportsIncludeLiveActivity { get; init; }

    public IReadOnlyList<string> Exports { get; init; } = new[] { "Excel" };

    public bool HasParameter(ReportParameterKind kind) => (Parameters & kind) == kind;
}

/// <summary>
/// The seven Report Center definitions. Facts (proc names, params, "All"
/// sentinels) verified live against CORECSERP_002_DEV — see the exact
/// parameter binding in SqlReportRepository.RunReportAsync. Do not add a
/// branch parameter to ConsolidatedGLWithDate / IncomeStatementAllBranchesPivot:
/// neither proc has one; both are consolidated/all-branch by design.
/// </summary>
public static class ReportCatalog
{
    public static readonly IReadOnlyList<ReportDefinition> All = new List<ReportDefinition>
    {
        new()
        {
            ProcName = "sp_rpt_BalanceSheetWithDate",
            Title = "Balance Sheet",
            Description = "Assets, liabilities and equity as of a date, by section.",
            Category = "Financial Statements",
            RenderStyle = ReportRenderStyle.Statement,
            Parameters = ReportParameterKind.AsOfDate | ReportParameterKind.Branch
        },
        new()
        {
            ProcName = "sp_rpt_BalanceSheetLiveWithDate",
            Title = "Balance Sheet (Live)",
            Description = "Assets, liabilities and equity as of a date, including today's unposted ticket activity — real-time, ahead of the next GL Posting run.",
            Category = "Financial Statements",
            RenderStyle = ReportRenderStyle.Statement,
            Parameters = ReportParameterKind.AsOfDate | ReportParameterKind.Branch,
            SupportsIncludeZeroActivity = true,
            SupportsIncludeLiveActivity = true
        },
        new()
        {
            ProcName = "sp_rpt_TrialBalanceWithDate",
            Title = "Trial Balance",
            Description = "Every account's ending balance as of a date, debit/credit split.",
            Category = "Financial Statements",
            RenderStyle = ReportRenderStyle.Statement,
            Parameters = ReportParameterKind.AsOfDate | ReportParameterKind.Branch
        },
        new()
        {
            ProcName = "sp_rpt_IncomeStatementAllBranchesPivot",
            Title = "Income Statement (All Branches)",
            Description = "Revenue, COGS and gross profit for a period, one column per branch.",
            Category = "Financial Statements",
            RenderStyle = ReportRenderStyle.PivotStatement,
            Parameters = ReportParameterKind.DateRange
        },
        new()
        {
            ProcName = "sp_rpt_IncomeStatementLiveWithDate",
            Title = "Income Statement (Live)",
            Description = "Revenue, COGS and net income for a period, single-branch or consolidated, including today's unposted ticket activity — real-time, ahead of the next GL Posting run.",
            Category = "Financial Statements",
            RenderStyle = ReportRenderStyle.Grid,
            Parameters = ReportParameterKind.DateRange | ReportParameterKind.Branch,
            SupportsIncludeZeroActivity = true,
            SupportsIncludeLiveActivity = true
        },
        new()
        {
            ProcName = "sp_rpt_ConsolidatedGLWithDate",
            Title = "Consolidated General Ledger",
            Description = "Company-wide account balances (as of a date) or activity (over a range), with intercompany detail.",
            Category = "General Ledger",
            RenderStyle = ReportRenderStyle.Grid,
            // No @BranchCode on this proc — consolidated by design.
            Parameters = ReportParameterKind.AsOfDate | ReportParameterKind.DateRange
        },
        new()
        {
            ProcName = "sp_rpt_GLDetailLedgerWithDate",
            Title = "GL Detail Ledger",
            Description = "Daily activity for one account over a period, with opening/closing balances.",
            Category = "General Ledger",
            RenderStyle = ReportRenderStyle.Grid,
            Parameters = ReportParameterKind.DateRange | ReportParameterKind.Branch | ReportParameterKind.Account,
            AccountRequired = true
        },
        new()
        {
            ProcName = "sp_rpt_GLDetailTransactionReport",
            Title = "GL Detail Transaction Report",
            Description = "Transaction-level ledger detail over a period, optionally for one account.",
            Category = "General Ledger",
            RenderStyle = ReportRenderStyle.Grid,
            Parameters = ReportParameterKind.DateRange | ReportParameterKind.Branch | ReportParameterKind.Account,
            AccountRequired = false,
            SupportsIncludeZeroActivity = true
        },
        new()
        {
            ProcName = "sp_rpt_BankReconciliationWithDate",
            Title = "Bank Reconciliation",
            Description = "Book vs. bank-statement balance for one bank account, with unresolved items.",
            Category = "Bank",
            RenderStyle = ReportRenderStyle.Grid,
            Parameters = ReportParameterKind.AsOfDate | ReportParameterKind.Branch | ReportParameterKind.Account,
            AccountRequired = true
        }
    };

    public static ReportDefinition? Find(string procName) =>
        All.FirstOrDefault(d => string.Equals(d.ProcName, procName, StringComparison.OrdinalIgnoreCase));
}

/// <summary>
/// Everything needed to run one of the 7 procs. "All branches" / "all
/// accounts" MUST be represented as null/empty here, which the repository
/// then binds as true SQL NULL (DBNull.Value) — never an empty string,
/// never a sentinel code like '888' or 'ALL'. See CLAUDE.md and the
/// Report Center brief: passing '' silently returns an all-zero result.
/// </summary>
public sealed class ReportRunRequest
{
    public required string ProcName { get; init; }
    public DateOnly? AsOfDate { get; init; }
    public DateOnly? DateFrom { get; init; }
    public DateOnly? DateTo { get; init; }

    /// <summary>Null/empty/whitespace means "All Branches" -&gt; DBNull.Value.</summary>
    public string? BranchCode { get; init; }

    /// <summary>Null/empty/whitespace means "All Accounts" (only valid where
    /// the report's AccountRequired is false) -&gt; DBNull.Value.</summary>
    public string? AccountCode { get; init; }

    public bool IncludeZeroActivity { get; init; }

    /// <summary>
    /// Only meaningful for the two "Live" financial statement procs
    /// (sp_rpt_BalanceSheetLiveWithDate, sp_rpt_IncomeStatementLiveWithDate).
    /// Both procs require this bit explicitly (no SQL-side default), so it
    /// defaults to true here — omitting it from a request should still mean
    /// "show live activity", not "tie-out/posted-only".
    /// </summary>
    public bool IncludeLiveActivity { get; init; } = true;
}

/// <summary>Type tag for one generic result-set column, so the (frontend)
/// renderer can right-align numbers / dates and left-align text without
/// re-guessing from string content.</summary>
public enum ReportColumnType
{
    Text,
    Number,
    Date,
    Bool
}

public sealed class ReportColumn
{
    public required string Name { get; init; }
    public required ReportColumnType Type { get; init; }
}

/// <summary>One result set from a Report Center proc, read generically via
/// SqlDataReader.GetName/GetFieldType/GetValue. Rows are positional (index
/// matches Columns) rather than one class per report.</summary>
public sealed class ReportResultSet
{
    public IReadOnlyList<ReportColumn> Columns { get; set; } = Array.Empty<ReportColumn>();
    public IReadOnlyList<object?[]> Rows { get; set; } = Array.Empty<object?[]>();
}

/// <summary>The full output of running one Report Center proc.</summary>
public sealed class ReportRunResult
{
    public required string ProcName { get; init; }
    public required ReportRenderStyle RenderStyle { get; init; }
    public IReadOnlyList<ReportResultSet> ResultSets { get; set; } = Array.Empty<ReportResultSet>();
    public DateTime GeneratedAt { get; set; } = DateTime.Now;
}

/// <summary>
/// One row of dbo.vw_rpt_AccountBSClassification (see sql/06-account-bs-
/// classification.sql), keyed by AccountCode in the lookup this hangs off
/// of. Used only to enrich sp_rpt_BalanceSheetWithDate's result set 1 with
/// the section/hierarchy info that proc's flat AccountCode/Amount rows
/// don't carry on their own.
/// </summary>
public sealed class AccountBsClassification
{
    /// <summary>e.g. "1-Current Assets" .. "5-Equity"; null for non-BS
    /// (Revenue/COGS/Expense) accounts.</summary>
    public string? BSSection { get; init; }
    public int? IndentLevel { get; init; }
    public string? ParentAccountCode { get; init; }
}

/// <summary>
/// One postable (AccountType = 'D') account from dbo.ChartOfAccounts, for the
/// Report Center's Account parameter autosuggest (GLDetailLedgerWithDate,
/// GLDetailTransactionReport, BankReconciliationWithDate). AccountType = 'D'
/// is the correct postability filter per CLAUDE.md Hard Rule #3 — never
/// LevelNumber.
/// </summary>
public sealed class AccountOption
{
    public required string AccountCode { get; init; }
    public required string Description { get; init; }
}

/* ============================================================================
   TICKET DRILLDOWN

   Backs dbo.sp_rpt_TicketDrilldown(@TicketNumber) — clicking a transaction
   row in the GL Detail Transaction Report (which carries a TicketNumber)
   fetches this ticket's header + full GL legs. Two result sets: header is
   0 or 1 row, legs are 0..N. Header being null is the "not found / not
   posted" signal the controller turns into a 404 — never a 200 with an
   empty body — so the frontend can distinguish "no such ticket" from
   "ticket has no legs" (which would be unusual but is not the same thing).
============================================================================ */

/// <summary>Result set 1 of sp_rpt_TicketDrilldown — 0 or 1 row.</summary>
public sealed class TicketHeader
{
    public required string TicketNumber { get; init; }
    public required DateTime TicketDate { get; init; }
    public required int SupplementaryNumber { get; init; }
    public required string BranchCode { get; init; }
    public required string ReferenceNumber { get; init; }
    public required string ReferenceKey { get; init; }
    public required string Origin { get; init; }
    public required string Mnemonic { get; init; }
    public required string Remarks { get; init; }
    public required string Owner { get; init; }
    public required string EnteredBy { get; init; }
    public required string CheckedBy { get; init; }
    public required string ApprovedBy { get; init; }
    public required string Status { get; init; }
}

/// <summary>One row of result set 2 (GL legs) of sp_rpt_TicketDrilldown,
/// ordered by the proc Debit DESC, Credit DESC.</summary>
public sealed class TicketLeg
{
    public required string AccountCode { get; init; }
    public string? AccountTitle { get; init; }
    public char? Nature { get; init; }
    public required decimal Debit { get; init; }
    public required decimal Credit { get; init; }
    public required decimal SignedAmount { get; init; }
    public required string BranchCode { get; init; }
    public required string ReferenceKey { get; init; }
    public required string ReferenceNumber { get; init; }
    public required string CostCenter { get; init; }
    public required string Particulars { get; init; }
}

/// <summary>
/// Bundle returned by GetTicketDrilldownAsync. Header is null when the proc's
/// result set 1 has no row — i.e. the ticket does not exist or is not posted
/// — so the controller can distinguish "not found" (404) from "found but has
/// no legs" (200 with an empty Legs list, which would itself be worth
/// flagging but is a different case).
/// </summary>
public sealed class TicketDrilldownResult
{
    public TicketHeader? Header { get; init; }
    public IReadOnlyList<TicketLeg> Legs { get; init; } = Array.Empty<TicketLeg>();
}
