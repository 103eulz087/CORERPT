namespace CoreReporting.Models;

/* ============================================================================
   EXCEPTION CENTER — business-process red flags (Management + Audit only).

   Distinct from HealthCheckItem/sp_rpt_DataHealthCheck: that module verifies
   ledger math ties out. This module detects business-process exceptions
   (skipped controls, override patterns) via dbo.ExceptionDefinition +
   dbo.sp_rpt_ExceptionCenter_Summary/_Detail — see sql/15-exception-center.sql.

   Config-driven: today only SOD-SAME-PREP-APPR exists, but more exception
   codes land later as rows in ExceptionDefinition plus branches in the detail
   proc. Nothing here assumes exactly one row.
============================================================================ */

/// <summary>
/// One row of sp_rpt_ExceptionCenter_Summary's single result set — one row
/// per exception CURRENTLY implemented (ExceptionDefinition.IsActive = 1),
/// joined to that day's Findings/ValueAtRisk. Same naming/shape philosophy as
/// HealthCheckItem: raw proc-supplied strings (Category, Severity) are kept
/// as-is rather than turned into enums.
/// </summary>
public sealed class ExceptionSummaryRow
{
    public string ExceptionCode { get; set; } = "";
    public string Category { get; set; } = "";
    public string Title { get; set; } = "";
    public string Severity { get; set; } = "";
    public int Findings { get; set; }

    /// <summary>Null when a check has zero findings or genuinely can't
    /// compute a value (see sql/15-exception-center.sql's methodology
    /// comment on gross ticket footing vs net economic exposure).</summary>
    public decimal? ValueAtRisk { get; set; }

    public bool HasDrillDown { get; set; }
    public string? DrillDownRoute { get; set; }
    public DateTime AsOf { get; set; }

    /// <summary>Mirrors HealthCheckItem.IsClean's exact convention.</summary>
    public bool IsClean => Findings == 0;
}

/// <summary>Everything the Exception Center landing page needs, in one
/// payload. No AllBranches/Branches here — this module has no @BranchCodes
/// parameter at all (see sql/15-exception-center.sql's procs), so the
/// top-bar branch chip stays hidden, same as SalesController/AgentScorecard.</summary>
public sealed class ExceptionCenterViewModel
{
    public FilterContext Filter { get; set; } = FilterContext.CurrentMonth();
    public IReadOnlyList<ExceptionSummaryRow> Rows { get; set; } = Array.Empty<ExceptionSummaryRow>();
    public DateTime GeneratedAt { get; set; } = DateTime.Now;
}
