namespace CoreReporting.Models;

/// <summary>
/// The global filter shown in the top bar. Carried on every request so
/// Period / Branch / Compare persist as the user navigates.
///
/// BranchCodes is a list of strings and never an int. '001' is not 1.
/// </summary>
public sealed class FilterContext
{
    public DateOnly DateFrom { get; set; }
    public DateOnly DateTo { get; set; }
    public List<string> BranchCodes { get; set; } = new();

    /// <summary>Comma separated for the SP parameter. Null means all branches.</summary>
    public string? BranchCsv =>
        BranchCodes.Count == 0 ? null : string.Join(',', BranchCodes);

    public static FilterContext CurrentMonth()
    {
        var today = DateOnly.FromDateTime(DateTime.Today);
        return new FilterContext
        {
            DateFrom = new DateOnly(today.Year, today.Month, 1),
            DateTo = today
        };
    }

    public string PeriodLabel =>
        $"{DateFrom:MMM d} \u2013 {DateTo:MMM d, yyyy}";
}

public sealed class Branch
{
    public string BranchCode { get; set; } = "";
    public string BranchName { get; set; } = "";
    public string DisplayText => $"{BranchCode}-{BranchName}";
}

/// <summary>Single row returned by sp_rpt_Exec_Summary.</summary>
public sealed class ExecSummary
{
    public DateTime AsOf { get; set; }
    public decimal NetSales { get; set; }
    public decimal NetSalesPrior { get; set; }
    public decimal OtherIncome { get; set; }
    public decimal Cogs { get; set; }
    public decimal CogsPrior { get; set; }
    public decimal GrossProfit { get; set; }
    public decimal? GrossMarginPct { get; set; }
    public decimal? GrossMarginPctPrior { get; set; }
    public decimal OperatingExpense { get; set; }
    public decimal OperatingExpensePrior { get; set; }
    public decimal NetIncome { get; set; }
    public decimal CashPosition { get; set; }
    public decimal ReceivablesTrade { get; set; }
    public decimal PayablesTrade { get; set; }
    public decimal InventoryOnHand { get; set; }
    public decimal InventoryInTransit { get; set; }

    /// <summary>Percentage change vs the prior period. Null when there is no base.</summary>
    public static decimal? PctChange(decimal current, decimal prior) =>
        prior == 0 ? null : (current - prior) / Math.Abs(prior) * 100m;

    public decimal? NetSalesDeltaPct => PctChange(NetSales, NetSalesPrior);
    public decimal? OpExDeltaPct => PctChange(OperatingExpense, OperatingExpensePrior);
    public decimal? MarginDeltaPts =>
        GrossMarginPct.HasValue && GrossMarginPctPrior.HasValue
            ? GrossMarginPct.Value - GrossMarginPctPrior.Value
            : null;
}

public sealed class SalesTrendPoint
{
    public DateTime MonthStart { get; set; }
    public string MonthLabel { get; set; } = "";
    public decimal NetSales { get; set; }
    public decimal Cogs { get; set; }
    public decimal GrossProfit { get; set; }
    public decimal? GrossMarginPct { get; set; }
}

public sealed class BranchScorecardRow
{
    public string BranchCode { get; set; } = "";
    public string BranchName { get; set; } = "";
    public string DisplayText { get; set; } = "";
    public decimal NetSales { get; set; }
    public decimal Cogs { get; set; }
    public decimal OperatingExpense { get; set; }
    public decimal GrossProfit { get; set; }
    public decimal? GrossMarginPct { get; set; }
    public decimal Receivables { get; set; }
    public decimal Inventory { get; set; }
    public decimal Payables { get; set; }
}

/// <summary>One row of sp_rpt_Exec_InventoryByBranch — current on-hand
/// quantity/value per branch, always every branch (LEFT JOIN from
/// dbo.Branches), including ones with zero inventory. No date/branch
/// parameters: dbo.Inventory is a current-state-only table (no historical
/// snapshot mechanism exists — confirmed, see sql/24's header), so this is
/// always "right now", not point-in-time.</summary>
public sealed class BranchInventoryRow
{
    public string BranchCode { get; set; } = "";
    public string BranchName { get; set; } = "";
    public string DisplayText { get; set; } = "";
    public decimal OnHandQuantity { get; set; }
    public decimal OnHandValue { get; set; }
    public int ItemCount { get; set; }

    /// <summary>How much of OnHandQuantity/OnHandValue has no captured cost
    /// (Cost = 0 or NULL) — OnHandValue is understated by roughly this much
    /// for a branch where this is non-trivial (largely Head Office today,
    /// see sql/24's header). Never hide this in the headline figure.</summary>
    public int ZeroCostItemCount { get; set; }
    public decimal ZeroCostQuantity { get; set; }

    /// <summary>Null when the branch has zero on-hand quantity (divide-by-zero
    /// guard in the proc) — never coerced to 0, which would misreport "no
    /// data" as "no cost gap".</summary>
    public decimal? ZeroCostQuantityPct { get; set; }

    public DateTime AsOf { get; set; }
}

/// <summary>One row of sp_rpt_Exec_CashPosition — a single (AccountCode,
/// BranchCode) cash/bank balance as of a point in time (not a date-range
/// flow; see sql/25's header). Ties out exactly to ExecSummary.CashPosition
/// when summed unfiltered for the same AsOf date.
///
/// Two caveats that MUST stay visible in any view over this data, not just
/// in this comment (see sql/25's data-quality notes, confirmed by
/// accounting-reviewer):
/// 1. This ledger has no recorded opening balance before 2026-07-24 — every
///    balance here excludes whatever should have been carried in, so an
///    individual account's absolute figure (especially a negative one) is
///    not proof of an overdraft, just an artifact of the missing opening
///    entry. Never render these negatives with the risk-red palette color —
///    that color is rationed for genuine money-at-risk, not a data gap.
/// 2. "USD"/"EURO" in AccountName are legacy/cosmetic labels only — this
///    ERP has no currency/FX table anywhere, confirmed live. Every balance
///    here, regardless of AccountName, is already Philippine pesos.</summary>
public sealed class CashPositionRow
{
    public string AccountCode { get; set; } = "";
    public string AccountName { get; set; } = "";
    public string Classification { get; set; } = "";
    public string BranchCode { get; set; } = "";
    public string BranchName { get; set; } = "";
    public string DisplayText { get; set; } = "";
    public decimal Balance { get; set; }
    public DateTime AsOf { get; set; }
}

public sealed class FlowStage
{
    public int StageOrder { get; set; }
    public string StageKey { get; set; } = "";
    public string StageLabel { get; set; } = "";
    public decimal? Amount { get; set; }

    /// <summary>
    /// False for Open POs and Open Orders: those are commitments that have
    /// not reached the general ledger, so they need the purchasing and sales
    /// order tables. The view renders them as pending rather than as zero,
    /// because zero would be a lie.
    /// </summary>
    public bool IsAvailable { get; set; }
}

public sealed class HealthCheckItem
{
    public int Seq { get; set; }
    public string CheckName { get; set; } = "";
    public string Severity { get; set; } = "";
    public int Findings { get; set; }
    public decimal? ValueAtRisk { get; set; }
    public bool IsClean => Findings == 0;
}

/// <summary>Everything the executive dashboard needs, in one payload.</summary>
public sealed class ExecutiveDashboardViewModel
{
    public FilterContext Filter { get; set; } = FilterContext.CurrentMonth();
    public IReadOnlyList<Branch> AllBranches { get; set; } = Array.Empty<Branch>();
    public ExecSummary Summary { get; set; } = new();
    public IReadOnlyList<SalesTrendPoint> Trend { get; set; } = Array.Empty<SalesTrendPoint>();
    public IReadOnlyList<BranchScorecardRow> Branches { get; set; } = Array.Empty<BranchScorecardRow>();
    public IReadOnlyList<FlowStage> Flow { get; set; } = Array.Empty<FlowStage>();
    public IReadOnlyList<BranchInventoryRow> InventoryByBranch { get; set; } = Array.Empty<BranchInventoryRow>();
    public IReadOnlyList<CashPositionRow> CashPosition { get; set; } = Array.Empty<CashPositionRow>();
    public DateTime GeneratedAt { get; set; } = DateTime.Now;
}
