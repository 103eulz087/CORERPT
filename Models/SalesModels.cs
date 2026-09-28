namespace CoreReporting.Models;

/* ============================================================================
   SALES MODULE — Agent Scorecard

   Mirrors sp_rpt_Agent_Scorecard exactly (see sql/14-agent-scorecard.sql).
   Property names are idiomatic C#; the exact SP column strings are only
   referenced inside SqlReportRepository's GetOrdinal calls. No branch
   dimension anywhere here — this proc has no @BranchCodes parameter (see the
   proc header: a sales agent's book is not confined to one branch).
============================================================================ */

/// <summary>
/// One row of sp_rpt_Agent_Scorecard's single result set — one row per named
/// agent, plus an always-present 'UNASSIGNED' row and an always-present
/// 'TOTAL' rollup row (see the proc header for why those two are never
/// dropped, even when @AgentNames filters the named-agent rows).
/// </summary>
public sealed class AgentScorecardRow
{
    public string AgentLabel { get; set; } = "";

    /// <summary>Raw proc-supplied classification: 'AGENT', 'UNASSIGNED', or
    /// 'TOTAL'. Kept as-is rather than turned into an enum, matching this
    /// app's existing convention (e.g. HealthCheckItem.Severity).</summary>
    public string RowType { get; set; } = "";

    public decimal NetSales { get; set; }
    public decimal NetSalesPrior { get; set; }
    public int TotalAssignedAccounts { get; set; }
    public int ActiveAccounts { get; set; }
    public int DormantAccounts { get; set; }
    public int NewAccounts { get; set; }
    public decimal AROutstanding { get; set; }
    public decimal ARPastDue31Plus { get; set; }

    /// <summary>Null when AROutstanding is 0 (the proc's divide-by-zero guard).</summary>
    public decimal? ARPastDuePct { get; set; }

    /// <summary>Null when the agent's book has no open AR items at all.</summary>
    public int? OldestOpenItemAgeDays { get; set; }

    public decimal NetSales90Day { get; set; }

    /// <summary>Null when trailing 90-day net sales is &lt;= 0 (the proc's
    /// divide-by-zero guard). See the proc header re: why TOTAL.DSO will not
    /// exactly equal sp_rpt_AR_Aging's own company DSO.</summary>
    public decimal? DSO { get; set; }

    /// <summary>Percentage change vs the prior period. Null when there is no
    /// base. Same PctChange logic/sign convention as ExecSummary.PctChange —
    /// do not diverge.</summary>
    public static decimal? PctChange(decimal current, decimal prior) =>
        prior == 0 ? null : (current - prior) / Math.Abs(prior) * 100m;

    public decimal? NetSalesDeltaPct => PctChange(NetSales, NetSalesPrior);
}

/// <summary>Everything the Agent Scorecard page needs, in one payload.
/// Mirrors FinanceOverviewViewModel's shape. No AllBranches here — this
/// dashboard has no branch dimension, so the top-bar branch chip stays
/// hidden (the controller simply never populates ViewBag.Branches).</summary>
public sealed class AgentScorecardViewModel
{
    public FilterContext Filter { get; set; } = FilterContext.CurrentMonth();
    public IReadOnlyList<AgentScorecardRow> Rows { get; set; } = Array.Empty<AgentScorecardRow>();
    public DateTime GeneratedAt { get; set; } = DateTime.Now;
}
