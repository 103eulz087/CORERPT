namespace CoreReporting.Models;

/* ============================================================================
   PART A — Finance Overview (AR / AP aging)

   Mirrors sp_rpt_AR_Aging / sp_rpt_AP_Aging exactly (see sql/05-accounting-
   aging.sql). Property names are idiomatic C#; the exact SP column strings
   are only referenced inside SqlReportRepository's GetOrdinal calls.
============================================================================ */

/// <summary>One row of sp_rpt_AR_Aging result set 1 — one row per customer.</summary>
public sealed class ArAgingRow
{
    public string CustomerKey { get; set; } = "";
    public string CustomerName { get; set; } = "";

    /// <summary>Customer's HOME branch (Customers.BranchCode), or "UNKNOWN"
    /// when the customer master has no matching row. Never the invoice's own
    /// branch — see the proc header note.</summary>
    public string BranchCode { get; set; } = "";

    public decimal CurrentAmount { get; set; }
    public decimal PastDue1To30 { get; set; }
    public decimal PastDue31To60 { get; set; }
    public decimal PastDue61To90 { get; set; }
    public decimal PastDue90Plus { get; set; }
    public decimal TotalOutstanding { get; set; }

    /// <summary>Null when the customer master has no credit limit on file.</summary>
    public decimal? CreditLimit { get; set; }
    public int? Term { get; set; }

    /// <summary>Null when CreditLimit is null or zero (divide-by-zero guard in the proc).</summary>
    public decimal? ExposurePct { get; set; }
    public int OldestAgeDays { get; set; }
}

/// <summary>One row of sp_rpt_AP_Aging result set 1 — one row per supplier,
/// including synthetic "UNKNOWN SUPPLIER - &lt;id&gt;" rows. Never filtered out.</summary>
public sealed class ApAgingRow
{
    public string SupplierId { get; set; } = "";
    public string SupplierName { get; set; } = "";
    public decimal CurrentAmount { get; set; }
    public decimal PastDue1To30 { get; set; }
    public decimal PastDue31To60 { get; set; }
    public decimal PastDue61To90 { get; set; }
    public decimal PastDue90Plus { get; set; }
    public decimal TotalOutstanding { get; set; }
    public int OldestAgeDays { get; set; }
}

/// <summary>
/// A bucketed total row. Used for the AR branch rollup (sp_rpt_AR_Aging result
/// set 2, one row per branch plus a 'TOTAL' row) and for the single AP
/// company-wide rollup (sp_rpt_AP_Aging result set 2 — Label is set to
/// "TOTAL" in code since that result set has no label column of its own).
/// </summary>
public sealed class AgingBucketTotals
{
    public string Label { get; set; } = "";
    public decimal CurrentAmount { get; set; }
    public decimal PastDue1To30 { get; set; }
    public decimal PastDue31To60 { get; set; }
    public decimal PastDue61To90 { get; set; }
    public decimal PastDue90Plus { get; set; }
    public decimal TotalOutstanding { get; set; }
}

/// <summary>sp_rpt_AR_Aging result set 3 — single row, company-wide DSO.
/// Not filtered by branch and not broken out per branch: AR ages by the
/// customer's HOME branch while net sales is booked to the SELLING branch,
/// so a branch-level ratio of the two would be apples to oranges.</summary>
public sealed class DsoInfo
{
    public DateOnly AsOfDate { get; set; }
    public decimal AROutstanding { get; set; }
    public decimal NetSales90Day { get; set; }
    public int TrailingDays { get; set; }

    /// <summary>Null when trailing net sales is &lt;= 0 (the proc's divide-by-zero guard).</summary>
    public decimal? Dso { get; set; }
}

/// <summary>Everything sp_rpt_AR_Aging returns, bundled.</summary>
public sealed class ArAgingResult
{
    public IReadOnlyList<ArAgingRow> Customers { get; set; } = Array.Empty<ArAgingRow>();
    public IReadOnlyList<AgingBucketTotals> BranchTotals { get; set; } = Array.Empty<AgingBucketTotals>();
    public DsoInfo Dso { get; set; } = new();
}

/// <summary>Everything sp_rpt_AP_Aging returns, bundled. No branch dimension:
/// APAccounts has no branch attribution in this schema.</summary>
public sealed class ApAgingResult
{
    public IReadOnlyList<ApAgingRow> Suppliers { get; set; } = Array.Empty<ApAgingRow>();
    public AgingBucketTotals CompanyTotal { get; set; } = new();
}

/// <summary>One row of sp_rpt_APEXP_Aging result set 1 — one row per supplier
/// (non-trade AP / ExpenseSummary), including synthetic "UNKNOWN SUPPLIER -
/// &lt;id&gt;" rows. Never filtered out. Mirrors ApAgingRow exactly; kept as a
/// distinct type since this is a different subledger (ExpenseSummary, not
/// APAccounts) — see sql/09-apexp-aging.sql.</summary>
public sealed class ApExpAgingRow
{
    public string SupplierId { get; set; } = "";
    public string SupplierName { get; set; } = "";
    public decimal CurrentAmount { get; set; }
    public decimal PastDue1To30 { get; set; }
    public decimal PastDue31To60 { get; set; }
    public decimal PastDue61To90 { get; set; }
    public decimal PastDue90Plus { get; set; }
    public decimal TotalOutstanding { get; set; }
    public int OldestAgeDays { get; set; }
}

/// <summary>Everything sp_rpt_APEXP_Aging returns, bundled. No branch
/// dimension: ExpenseSummary has no branch attribution in this schema
/// (same situation as APAccounts).</summary>
public sealed class ApExpAgingResult
{
    public IReadOnlyList<ApExpAgingRow> Suppliers { get; set; } = Array.Empty<ApExpAgingRow>();
    public AgingBucketTotals CompanyTotal { get; set; } = new();
}

/// <summary>One row of sp_rpt_DailyBranchActivity result set 1 — one row per
/// branch with invoice activity for the day, sorted TotalAmount DESC by the
/// proc. Branches with zero activity simply do not appear.</summary>
public sealed class DailyBranchActivityRow
{
    public string BranchCode { get; set; } = "";
    public string BranchName { get; set; } = "";
    public int InvoiceCount { get; set; }
    public decimal TotalAmount { get; set; }
}

/// <summary>sp_rpt_DailyBranchActivity result set 2 — single company-wide
/// rollup row, always present and zero-safe (never NULL columns).</summary>
public sealed class DailyActivityTotal
{
    public int InvoiceCount { get; set; }
    public decimal TotalAmount { get; set; }
}

/// <summary>Everything sp_rpt_DailyBranchActivity returns, bundled. This is a
/// "today's activity" widget, not an aging report — see
/// AccountingDashboardService for its distinct, much shorter cache window.</summary>
public sealed class DailyBranchActivityResult
{
    public IReadOnlyList<DailyBranchActivityRow> Branches { get; set; } = Array.Empty<DailyBranchActivityRow>();
    public DailyActivityTotal CompanyTotal { get; set; } = new();
}

/// <summary>Everything the Finance Overview dashboard needs, in one payload.</summary>
public sealed class FinanceOverviewViewModel
{
    public FilterContext Filter { get; set; } = FilterContext.CurrentMonth();
    public IReadOnlyList<Branch> AllBranches { get; set; } = Array.Empty<Branch>();
    public ArAgingResult Ar { get; set; } = new();
    public ApAgingResult Ap { get; set; } = new();
    public ApExpAgingResult ApExp { get; set; } = new();

    /// <summary>Today's per-branch invoice activity (sp_rpt_DailyBranchActivity).
    /// Not filtered by the dashboard's period/branch filter — it is always
    /// "today", independent of Filter.DateFrom/DateTo.</summary>
    public DailyBranchActivityResult DailyActivity { get; set; } = new();

    public DateTime GeneratedAt { get; set; } = DateTime.Now;

    /// <summary>AR is aged as of the filter's DateTo; AP shares the same as-of
    /// date even though it has no branch filter of its own.</summary>
    public DateOnly AsOfDate => Filter.DateTo;
}
